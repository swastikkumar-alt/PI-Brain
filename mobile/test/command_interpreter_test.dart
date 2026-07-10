import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/models/phone_action.dart';
import 'package:pie_mobile/services/command_interpreter.dart';
import 'package:pie_mobile/services/contact_resolution.dart';
import 'package:pie_mobile/services/manual_recipient_factory.dart';
import 'package:pie_mobile/services/message_drafting_service.dart';

void main() {
  group('CommandInterpreter', () {
    const interpreter = CommandInterpreter();

    test('parses spoken WhatsApp command with recipient and body', () {
      final result = interpreter.parse(
        'message nalayak that i am not coming today on whatsapp',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.type, PhoneActionType.whatsappMessage);
      expect(command.recipientQuery, 'nalayak');
      expect(command.messageBody, 'i am not coming today');
      expect(command.targetApp, 'whatsapp');
    });

    test('parses direct WhatsApp phrasing', () {
      final result = interpreter.parse(
        'send WhatsApp message to Rahul saying meeting moved to 5',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.recipientQuery, 'Rahul');
      expect(command.messageBody, 'meeting moved to 5');
    });

    test('parses phone-number WhatsApp recipient', () {
      final result = interpreter.parse(
        'message +91 98765 43210 that i am not coming today on whatsapp',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.type, PhoneActionType.whatsappMessage);
      expect(command.recipientQuery, '+91 98765 43210');
      expect(command.intent, 'absence');
    });

    test('extracts formal tone directive from WhatsApp message', () {
      final result = interpreter.parse(
        'message 9458420654 that sir, i am sick and not come tomm formalize it',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.recipientQuery, '9458420654');
      expect(command.messageBody, 'sir, i am sick and not come tomm');
      expect(command.requestedTone, MessageTone.professional);
    });

    test('parses email command with email address recipient', () {
      final result = interpreter.parse(
        'email rahul@example.com that meeting moved to 5',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.type, PhoneActionType.emailMessage);
      expect(command.recipientQuery, 'rahul@example.com');
      expect(command.messageBody, 'meeting moved to 5');
      expect(command.intent, 'meeting');
    });

    test('parses email attachment request without adding it to body', () {
      final result = interpreter.parse(
        'email rahul@example.com that please review the proposal and attach document proposal.pdf',
      );

      expect(result, isA<ParsedPhoneCommand>());
      final command = result as ParsedPhoneCommand;
      expect(command.type, PhoneActionType.emailMessage);
      expect(command.messageBody, 'please review the proposal');
      expect(command.emailAttachmentRequested, isTrue);
      expect(command.emailAttachmentHint, 'proposal.pdf');
    });

    test('rejects unsupported commands', () {
      final result = interpreter.parse('delete all spam from my phone');

      expect(result, isA<UnsupportedPhoneCommand>());
    });
  });

  group('ContactResolutionEngine', () {
    const engine = ContactResolutionEngine();

    test('selects one exact contact match', () {
      final resolution = engine.resolve(
        query: 'Rahul',
        candidates: const [
          ContactCandidate(
            id: '1',
            displayName: 'Rahul',
            phoneNumber: '+15550000001',
            normalizedPhoneNumber: '+15550000001',
          ),
        ],
      );

      expect(resolution.isResolved, isTrue);
      expect(resolution.selected?.id, '1');
    });

    test('asks for disambiguation on multiple exact matches', () {
      final resolution = engine.resolve(
        query: 'Rahul',
        candidates: const [
          ContactCandidate(
            id: '1',
            displayName: 'Rahul',
            phoneNumber: '+15550000001',
            normalizedPhoneNumber: '+15550000001',
          ),
          ContactCandidate(
            id: '2',
            displayName: 'Rahul',
            phoneNumber: '+15550000002',
            normalizedPhoneNumber: '+15550000002',
          ),
        ],
      );

      expect(resolution.needsDisambiguation, isTrue);
      expect(resolution.candidates, hasLength(2));
    });

    test('suggests similar contact when name has a small spelling error', () {
      final resolution = engine.resolve(
        query: 'Rhul',
        candidates: const [
          ContactCandidate(
            id: '1',
            displayName: 'Rahul Sharma',
            phoneNumber: '+15550000001',
            normalizedPhoneNumber: '+15550000001',
          ),
          ContactCandidate(
            id: '2',
            displayName: 'Ankit',
            phoneNumber: '+15550000002',
            normalizedPhoneNumber: '+15550000002',
          ),
        ],
      );

      expect(resolution.isResolved, isFalse);
      expect(resolution.needsDisambiguation, isTrue);
      expect(resolution.candidates.single.displayName, 'Rahul Sharma');
    });
  });

  group('ManualRecipientFactory', () {
    const interpreter = CommandInterpreter();
    const factory = ManualRecipientFactory();

    test('creates manual phone recipient from WhatsApp command', () {
      final command =
          interpreter.parse('message +91 98765 43210 that hello on whatsapp')
              as ParsedPhoneCommand;

      final recipient = factory.fromCommand(command);

      expect(recipient?.recipientKind, RecipientKind.manualPhone);
      expect(recipient?.normalizedPhoneNumber, '+919876543210');
    });

    test('creates manual email recipient from email command', () {
      final command =
          interpreter.parse('email Rahul@Example.com that hello')
              as ParsedPhoneCommand;

      final recipient = factory.fromCommand(command);

      expect(recipient?.recipientKind, RecipientKind.manualEmail);
      expect(recipient?.emailAddress, 'rahul@example.com');
    });
  });

  group('MessageDraftingService', () {
    const drafting = MessageDraftingService();

    test('preserves Hindi text format', () {
      final draft = drafting.createDraft(
        rawMessage: 'मैं आज नहीं आ पाऊंगा',
        actionType: PhoneActionType.whatsappMessage,
        relationshipType: RelationshipType.friend,
      );

      expect(draft.language, MessageLanguage.hindi);
      expect(draft.body, contains('मैं आज नहीं आ पाऊंगा'));
    });

    test('preserves Hinglish text format', () {
      final draft = drafting.createDraft(
        rawMessage: 'main aaj nahi aa paunga',
        actionType: PhoneActionType.whatsappMessage,
        relationshipType: RelationshipType.friend,
      );

      expect(draft.language, MessageLanguage.hinglish);
      expect(draft.body, contains('main aaj nahi aa paunga'));
    });

    test('uses professional tone for professional relationship', () {
      final tone = drafting.defaultToneForRelationship(
        RelationshipType.professional,
      );

      expect(tone, MessageTone.professional);
    });

    test('formalizes dictated absence message without changing intent', () {
      final draft = drafting.createDraft(
        rawMessage: 'sir, i am sick and not come tomm',
        actionType: PhoneActionType.whatsappMessage,
        relationshipType: RelationshipType.unknown,
        requestedTone: MessageTone.professional,
        intent: 'absence',
      );

      expect(draft.tone, MessageTone.professional);
      expect(
        draft.body,
        'Sir, I am sick and will not be able to come tomorrow.',
      );
    });
  });
}
