import 'package:uuid/uuid.dart';

import '../models/phone_action.dart';
import 'accessibility_bridge.dart';
import 'command_interpreter.dart';
import 'contact_resolution.dart';
import 'database_service.dart';
import 'email_connector_service.dart';
import 'manual_recipient_factory.dart';
import 'message_drafting_service.dart';
import 'native_contact_service.dart';
import 'whatsapp_connector_service.dart';

class ActionPlanningResult {
  const ActionPlanningResult({this.plan, this.unsupportedReason});

  final PhoneActionPlan? plan;
  final String? unsupportedReason;

  bool get hasPlan => plan != null;
}

class ActionApprovalController {
  ActionApprovalController({
    CommandInterpreter? interpreter,
    ContactResolutionEngine? contactResolutionEngine,
    DatabaseService? database,
    NativeContactService? contactService,
    AccessibilityBridge? accessibilityBridge,
    WhatsAppConnectorService? whatsAppConnector,
    EmailConnectorService? emailConnector,
    MessageDraftingService? draftingService,
    ManualRecipientFactory? manualRecipientFactory,
  }) : _interpreter = interpreter ?? const CommandInterpreter(),
       _contactResolutionEngine =
           contactResolutionEngine ?? const ContactResolutionEngine(),
       _db = database ?? DatabaseService.instance,
       _contactService = contactService ?? NativeContactService.instance,
       _accessibilityBridge =
           accessibilityBridge ?? AccessibilityBridge.instance,
       _whatsAppConnector =
           whatsAppConnector ?? WhatsAppConnectorService.instance,
       _emailConnector = emailConnector ?? EmailConnectorService.instance,
       _draftingService = draftingService ?? const MessageDraftingService(),
       _manualRecipientFactory =
           manualRecipientFactory ?? const ManualRecipientFactory();

  final CommandInterpreter _interpreter;
  final ContactResolutionEngine _contactResolutionEngine;
  final DatabaseService _db;
  final NativeContactService _contactService;
  final AccessibilityBridge _accessibilityBridge;
  final WhatsAppConnectorService _whatsAppConnector;
  final EmailConnectorService _emailConnector;
  final MessageDraftingService _draftingService;
  final ManualRecipientFactory _manualRecipientFactory;
  final Uuid _uuid = const Uuid();

  Future<ActionPlanningResult> planCommand(String rawCommand) async {
    final parsed = _interpreter.parse(rawCommand);
    if (parsed is UnsupportedPhoneCommand) {
      return ActionPlanningResult(unsupportedReason: parsed.reason);
    }
    if (parsed is! ParsedPhoneCommand) {
      return const ActionPlanningResult(
        unsupportedReason: 'Command could not be parsed.',
      );
    }

    final plan = PhoneActionPlan(
      id: _uuid.v4(),
      type: parsed.type,
      rawCommand: parsed.rawCommand,
      recipientQuery: parsed.recipientQuery,
      messageBody: parsed.messageBody,
      targetApp: parsed.targetApp,
      createdAt: DateTime.now(),
      intent: parsed.intent,
      requestedTone: parsed.requestedTone,
      emailAttachmentRequested: parsed.emailAttachmentRequested,
      emailAttachmentHint: parsed.emailAttachmentHint,
    );

    if (!await _isConnectorAvailable(plan.type)) {
      plan.blockedReason = plan.type == PhoneActionType.emailMessage
          ? 'No email app is available for compose.'
          : 'WhatsApp is not installed or is unavailable.';
      await _db.recordActionAudit(plan, PhoneActionStatus.planned);
      return ActionPlanningResult(plan: plan);
    }

    final manualRecipient = _manualRecipientFactory.fromCommand(parsed);
    if (manualRecipient != null) {
      plan.contact = manualRecipient;
      await _db.upsertManualRecipient(manualRecipient);
      await _applyProfileAndDraft(plan);
      await _db.recordActionAudit(plan, PhoneActionStatus.planned);
      return ActionPlanningResult(plan: plan);
    }

    final aliasContact = await _db.getContactAlias(parsed.recipientQuery);
    if (aliasContact != null) {
      plan.contact = aliasContact;
      await _applyProfileAndDraft(plan);
      await _db.recordActionAudit(plan, PhoneActionStatus.planned);
      return ActionPlanningResult(plan: plan);
    }

    if (!await _contactService.checkPermission()) {
      plan.blockedReason =
          'Contacts permission is required to resolve recipient.';
      await _db.recordActionAudit(plan, PhoneActionStatus.planned);
      return ActionPlanningResult(plan: plan);
    }

    var candidates = parsed.type == PhoneActionType.emailMessage
        ? await _contactService.searchEmailContacts(parsed.recipientQuery)
        : await _contactService.searchContacts(parsed.recipientQuery);
    var resolution = _contactResolutionEngine.resolve(
      query: parsed.recipientQuery,
      candidates: candidates,
    );

    if (resolution.isBlocked) {
      candidates = parsed.type == PhoneActionType.emailMessage
          ? await _contactService.listEmailContacts()
          : await _contactService.listPhoneContacts();
      resolution = _contactResolutionEngine.resolve(
        query: parsed.recipientQuery,
        candidates: candidates,
      );
    }

    if (resolution.isResolved) {
      plan.contact = resolution.selected;
      await _applyProfileAndDraft(plan);
    } else if (resolution.needsDisambiguation) {
      plan.candidates = resolution.candidates;
    } else {
      plan.blockedReason = resolution.reason ?? 'No matching contact found.';
    }

    await _db.recordActionAudit(plan, PhoneActionStatus.planned);
    return ActionPlanningResult(plan: plan);
  }

  Future<PhoneActionPlan> chooseCandidate(
    PhoneActionPlan plan,
    ContactCandidate contact,
  ) async {
    plan.contact = contact;
    plan.candidates = const [];
    plan.blockedReason = null;
    await _db.upsertContactAlias(plan.recipientQuery, contact);
    await _applyProfileAndDraft(plan);
    await _db.recordActionAudit(plan, PhoneActionStatus.planned);
    return plan;
  }

  Future<PhoneActionPlan> updateDraftPreferences(
    PhoneActionPlan plan, {
    required RelationshipType relationshipType,
    required MessageTone tone,
    required String finalText,
    String? emailSubject,
    List<String>? emailAttachmentPaths,
  }) async {
    plan.relationshipType = relationshipType;
    plan.tone = tone;
    plan.finalText = finalText;
    if (emailSubject != null) plan.emailSubject = emailSubject;
    if (emailAttachmentPaths != null) {
      plan.emailAttachmentPaths = emailAttachmentPaths;
    }

    final contact = plan.contact;
    if (contact != null) {
      await _db.upsertContactProfile(
        contact,
        relationshipType: relationshipType,
        preferredTone: tone,
        languagePreference: plan.language,
      );
    }
    await _db.recordMessageDraft(plan);
    await _db.recordActionAudit(plan, PhoneActionStatus.planned);
    return plan;
  }

  Future<PhoneActionExecutionResult> approveAndExecute(
    PhoneActionPlan plan,
  ) async {
    if (plan.isBlocked) {
      final result = PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: plan.blockedReason ?? 'Action is blocked.',
      );
      await _db.recordActionAudit(
        plan,
        PhoneActionStatus.failed,
        resultText: result.message,
      );
      return result;
    }

    if (plan.contact == null) {
      const result = PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: 'Choose a verified contact before approving this action.',
      );
      await _db.recordActionAudit(
        plan,
        PhoneActionStatus.failed,
        resultText: result.message,
      );
      return result;
    }

    if (plan.type == PhoneActionType.whatsappMessage &&
        plan.unlockPolicy == AppUnlockPolicy.skipLockedApps) {
      const result = PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message:
            'WhatsApp automation skipped because locked-app handling is set to skip.',
      );
      await _db.recordActionAudit(
        plan,
        PhoneActionStatus.failed,
        resultText: result.message,
      );
      return result;
    }

    if (plan.type == PhoneActionType.whatsappMessage &&
        !await _accessibilityBridge.isEnabled()) {
      final policy = await _db.getAppUnlockPolicy();
      plan.unlockPolicy = policy;
      final message = switch (policy) {
        AppUnlockPolicy.skipLockedApps =>
          'WhatsApp automation is blocked by policy. Draft stays in PIE.',
        AppUnlockPolicy.sessionUnlock =>
          'Enable Capture Service in PIE Settings, then unlock WhatsApp once for this session.',
        AppUnlockPolicy.unlockEachTime =>
          'Enable Capture Service in PIE Settings, then unlock WhatsApp when prompted.',
      };
      final result = PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: message,
      );
      await _db.recordActionAudit(
        plan,
        PhoneActionStatus.failed,
        resultText: result.message,
      );
      return result;
    }

    plan.status = PhoneActionStatus.approved;
    await _db.recordActionAudit(plan, PhoneActionStatus.approved);

    await _db.recordMessageDraft(plan);
    final result = plan.type == PhoneActionType.emailMessage
        ? await _emailConnector.execute(plan)
        : await _whatsAppConnector.execute(plan);
    plan.status = result.status;
    await _db.recordActionAudit(
      plan,
      result.status,
      resultText: result.message,
    );
    return result;
  }

  Future<void> cancel(PhoneActionPlan plan) async {
    plan.status = PhoneActionStatus.cancelled;
    await _db.recordActionAudit(plan, PhoneActionStatus.cancelled);
  }

  Future<bool> _isConnectorAvailable(PhoneActionType type) {
    return type == PhoneActionType.emailMessage
        ? _emailConnector.isAvailable()
        : _whatsAppConnector.isAvailable();
  }

  Future<void> _applyProfileAndDraft(PhoneActionPlan plan) async {
    final contact = plan.contact;
    if (contact == null) return;

    final profile = await _db.getContactProfile(_db.contactProfileKey(contact));
    plan.relationshipType = _relationshipFromName(
      profile?['relationship_type']?.toString(),
    );
    final profileTone = _toneFromName(profile?['preferred_tone']?.toString());
    plan.tone = plan.requestedTone ?? profileTone;

    final draft = _draftingService.createDraft(
      rawMessage: plan.messageBody,
      actionType: plan.type,
      relationshipType: plan.relationshipType,
      requestedTone: plan.tone,
      recipientName: contact.safeLabel,
      intent: plan.intent,
    );

    plan.language = draft.language;
    plan.tone = draft.tone;
    plan.draftText = draft.body;
    plan.finalText ??= draft.body;
    plan.emailSubject = draft.subject;
    plan.unlockPolicy = await _db.getAppUnlockPolicy();
    await _db.recordMessageDraft(plan);
  }

  RelationshipType _relationshipFromName(String? value) {
    return RelationshipType.values.firstWhere(
      (relationship) => relationship.name == value,
      orElse: () => RelationshipType.unknown,
    );
  }

  MessageTone _toneFromName(String? value) {
    return MessageTone.values.firstWhere(
      (tone) => tone.name == value,
      orElse: () => MessageTone.neutral,
    );
  }
}
