import 'dart:convert';

enum PhoneActionType { whatsappMessage, emailMessage }

enum PhoneActionStatus { planned, approved, executed, failed, cancelled }

enum PhoneActionRisk { sensitive }

enum RecipientKind { contact, manualPhone, manualEmail }

enum RelationshipType { family, friend, professional, custom, unknown }

enum MessageTone { friendly, professional, neutral, custom }

enum MessageLanguage { english, hindi, hinglish, unknown }

enum AppUnlockPolicy { unlockEachTime, sessionUnlock, skipLockedApps }

class ParsedPhoneCommand {
  const ParsedPhoneCommand({
    required this.type,
    required this.rawCommand,
    required this.recipientQuery,
    required this.messageBody,
    required this.targetApp,
    this.intent = 'update',
    this.requestedTone,
    this.emailAttachmentRequested = false,
    this.emailAttachmentHint,
  });

  final PhoneActionType type;
  final String rawCommand;
  final String recipientQuery;
  final String messageBody;
  final String targetApp;
  final String intent;
  final MessageTone? requestedTone;
  final bool emailAttachmentRequested;
  final String? emailAttachmentHint;
}

class UnsupportedPhoneCommand {
  const UnsupportedPhoneCommand(this.reason);

  final String reason;
}

class ContactCandidate {
  const ContactCandidate({
    required this.id,
    required this.displayName,
    required this.phoneNumber,
    required this.normalizedPhoneNumber,
    this.emailAddress = '',
    this.source = 'contacts',
    this.recipientKind = RecipientKind.contact,
  });

  final String id;
  final String displayName;
  final String phoneNumber;
  final String normalizedPhoneNumber;
  final String emailAddress;
  final String source;
  final RecipientKind recipientKind;

  String get safeLabel {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (emailAddress.trim().isNotEmpty) return emailAddress.trim();
    if (normalizedPhoneNumber.length <= 4) return 'Contact';
    return 'Contact ending ${normalizedPhoneNumber.substring(normalizedPhoneNumber.length - 4)}';
  }

  String get routableAddress {
    if (recipientKind == RecipientKind.manualEmail) return emailAddress;
    if (emailAddress.isNotEmpty && normalizedPhoneNumber.isEmpty) {
      return emailAddress;
    }
    return normalizedPhoneNumber;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'phoneNumber': phoneNumber,
      'normalizedPhoneNumber': normalizedPhoneNumber,
      'emailAddress': emailAddress,
      'source': source,
      'recipientKind': recipientKind.name,
    };
  }

  factory ContactCandidate.fromJson(Map<String, dynamic> json) {
    final kindName = json['recipientKind']?.toString();
    return ContactCandidate(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      phoneNumber: json['phoneNumber']?.toString() ?? '',
      normalizedPhoneNumber: json['normalizedPhoneNumber']?.toString() ?? '',
      emailAddress: json['emailAddress']?.toString() ?? '',
      source: json['source']?.toString() ?? 'contacts',
      recipientKind: RecipientKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => RecipientKind.contact,
      ),
    );
  }
}

class PhoneActionPlan {
  PhoneActionPlan({
    required this.id,
    required this.type,
    required this.rawCommand,
    required this.recipientQuery,
    required this.messageBody,
    required this.targetApp,
    required this.createdAt,
    this.risk = PhoneActionRisk.sensitive,
    this.status = PhoneActionStatus.planned,
    this.contact,
    this.candidates = const [],
    this.blockedReason,
    this.relationshipType = RelationshipType.unknown,
    this.tone = MessageTone.neutral,
    this.language = MessageLanguage.unknown,
    this.intent = 'update',
    this.requestedTone,
    this.draftText,
    this.finalText,
    this.emailSubject,
    this.emailAttachmentRequested = false,
    this.emailAttachmentHint,
    this.emailAttachmentPaths = const [],
    this.unlockPolicy = AppUnlockPolicy.unlockEachTime,
  });

  final String id;
  final PhoneActionType type;
  final String rawCommand;
  final String recipientQuery;
  final String messageBody;
  final String targetApp;
  final DateTime createdAt;
  final PhoneActionRisk risk;
  PhoneActionStatus status;
  ContactCandidate? contact;
  List<ContactCandidate> candidates;
  String? blockedReason;
  RelationshipType relationshipType;
  MessageTone tone;
  MessageLanguage language;
  String intent;
  MessageTone? requestedTone;
  String? draftText;
  String? finalText;
  String? emailSubject;
  bool emailAttachmentRequested;
  String? emailAttachmentHint;
  List<String> emailAttachmentPaths;
  AppUnlockPolicy unlockPolicy;

  bool get isBlocked => blockedReason != null && blockedReason!.isNotEmpty;

  String get outgoingText => finalText?.trim().isNotEmpty == true
      ? finalText!.trim()
      : (draftText?.trim().isNotEmpty == true
            ? draftText!.trim()
            : messageBody);

  String get redactedSummary {
    final recipient = contact?.safeLabel ?? recipientQuery;
    final channel = type == PhoneActionType.emailMessage
        ? 'email'
        : 'WhatsApp message';
    return 'Send $channel to $recipient';
  }

  Map<String, dynamic> toJson({bool includeSensitive = true}) {
    return {
      'id': id,
      'type': type.name,
      'rawCommand': includeSensitive ? rawCommand : '[redacted]',
      'recipientQuery': includeSensitive ? recipientQuery : '[redacted]',
      'messageBody': includeSensitive ? messageBody : '[redacted]',
      'targetApp': targetApp,
      'createdAt': createdAt.toIso8601String(),
      'risk': risk.name,
      'status': status.name,
      'contact': contact?.toJson(),
      'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
      'blockedReason': blockedReason,
      'relationshipType': relationshipType.name,
      'tone': tone.name,
      'language': language.name,
      'intent': intent,
      'requestedTone': requestedTone?.name,
      'draftText': includeSensitive ? draftText : '[redacted]',
      'finalText': includeSensitive ? finalText : '[redacted]',
      'emailSubject': includeSensitive ? emailSubject : '[redacted]',
      'emailAttachmentRequested': emailAttachmentRequested,
      'emailAttachmentHint': includeSensitive
          ? emailAttachmentHint
          : '[redacted]',
      'emailAttachmentPaths': includeSensitive
          ? emailAttachmentPaths
          : emailAttachmentPaths.map((_) => '[redacted]').toList(),
      'unlockPolicy': unlockPolicy.name,
    };
  }

  String encodeForAudit() => jsonEncode(toJson(includeSensitive: true));
}

class MessageDraft {
  const MessageDraft({
    required this.language,
    required this.tone,
    required this.intent,
    required this.body,
    this.subject,
  });

  final MessageLanguage language;
  final MessageTone tone;
  final String intent;
  final String body;
  final String? subject;
}

class PhoneActionExecutionResult {
  const PhoneActionExecutionResult({
    required this.status,
    required this.message,
    this.rawDetails,
  });

  final PhoneActionStatus status;
  final String message;
  final Map<String, dynamic>? rawDetails;

  bool get isSuccess => status == PhoneActionStatus.executed;
}
