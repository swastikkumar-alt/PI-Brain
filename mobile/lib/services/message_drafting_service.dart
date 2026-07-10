import '../models/phone_action.dart';

class MessageDraftingService {
  const MessageDraftingService();

  MessageDraft createDraft({
    required String rawMessage,
    required PhoneActionType actionType,
    required RelationshipType relationshipType,
    MessageTone? requestedTone,
    String? recipientName,
    String intent = 'update',
  }) {
    final language = detectLanguage(rawMessage);
    final tone = requestedTone ?? defaultToneForRelationship(relationshipType);
    final body = _draftBody(
      rawMessage: rawMessage,
      actionType: actionType,
      relationshipType: relationshipType,
      tone: tone,
      language: language,
      recipientName: recipientName,
      intent: intent,
    );

    return MessageDraft(
      language: language,
      tone: tone,
      intent: intent,
      body: body,
      subject: actionType == PhoneActionType.emailMessage
          ? _inferSubject(intent, rawMessage)
          : null,
    );
  }

  MessageTone defaultToneForRelationship(RelationshipType relationshipType) {
    return switch (relationshipType) {
      RelationshipType.family => MessageTone.friendly,
      RelationshipType.friend => MessageTone.friendly,
      RelationshipType.professional => MessageTone.professional,
      RelationshipType.custom => MessageTone.custom,
      RelationshipType.unknown => MessageTone.neutral,
    };
  }

  MessageLanguage detectLanguage(String value) {
    final text = value.trim();
    if (text.isEmpty) return MessageLanguage.unknown;
    if (RegExp(r'[\u0900-\u097F]').hasMatch(text)) {
      return MessageLanguage.hindi;
    }

    final lower = text.toLowerCase();
    final hinglishTerms = [
      'nahi',
      'nahin',
      'haan',
      'kal',
      'aaj',
      'aa',
      'aana',
      'karna',
      'kya',
      'hai',
      'hoon',
      'hu',
      'bhai',
      'yaar',
      'mat',
      'kr',
      'kar',
      'mera',
      'tum',
      'apna',
    ];
    if (hinglishTerms.any((term) => RegExp('\\b$term\\b').hasMatch(lower))) {
      return MessageLanguage.hinglish;
    }
    return MessageLanguage.english;
  }

  String _draftBody({
    required String rawMessage,
    required PhoneActionType actionType,
    required RelationshipType relationshipType,
    required MessageTone tone,
    required MessageLanguage language,
    required String? recipientName,
    required String intent,
  }) {
    final message = _normalizeSpacing(rawMessage);
    if (message.isEmpty) return message;

    if (language == MessageLanguage.hindi ||
        language == MessageLanguage.hinglish) {
      return actionType == PhoneActionType.emailMessage
          ? _emailBody(message, tone, language, recipientName)
          : _ensureTerminalPunctuation(message, language);
    }

    if (tone == MessageTone.professional) {
      final professionalMessage = _professionalizeEnglish(message, intent);
      final sentence = _ensureTerminalPunctuation(
        _capitalizeFirst(professionalMessage),
        language,
      );
      if (actionType == PhoneActionType.emailMessage) {
        return _emailBody(sentence, tone, language, recipientName);
      }
      return sentence;
    }

    if (actionType == PhoneActionType.emailMessage) {
      return _emailBody(message, tone, language, recipientName);
    }

    return message;
  }

  String _professionalizeEnglish(String value, String intent) {
    var message = _normalizeSpacing(value)
        .replaceAll(
          RegExp(r'\btomm(?:orow)?\b', caseSensitive: false),
          'tomorrow',
        )
        .replaceAll(RegExp(r'\btmrw\b', caseSensitive: false), 'tomorrow')
        .replaceAll(RegExp(r'\bpls\b', caseSensitive: false), 'please')
        .replaceAll(RegExp(r"\bcan'?t\b", caseSensitive: false), 'cannot')
        .replaceAll(RegExp(r'\bi\s*(?:m|am)\b', caseSensitive: false), 'I am')
        .replaceAll(RegExp(r'\bi\b', caseSensitive: false), 'I');

    message = message.replaceAllMapped(
      RegExp(
        r'\b(?:will\s+)?not\s+come(?:\s+(today|tomorrow))?\b',
        caseSensitive: false,
      ),
      (match) {
        final when = match.group(1);
        return 'will not be able to come${when == null ? '' : ' $when'}';
      },
    );

    message = message.replaceAllMapped(
      RegExp(r'\bnot\s+coming(?:\s+(today|tomorrow))?\b', caseSensitive: false),
      (match) {
        final when = match.group(1);
        return 'will not be able to come${when == null ? '' : ' $when'}';
      },
    );

    if (intent == 'absence' && !message.toLowerCase().contains('sick')) {
      return message;
    }

    return _normalizeSpacing(message);
  }

  String _emailBody(
    String message,
    MessageTone tone,
    MessageLanguage language,
    String? recipientName,
  ) {
    final name = _firstName(recipientName);
    final greeting = switch (tone) {
      MessageTone.professional => name == null ? 'Hello,' : 'Hello $name,',
      MessageTone.friendly => name == null ? 'Hey,' : 'Hey $name,',
      MessageTone.custom => name == null ? 'Hello,' : 'Hello $name,',
      MessageTone.neutral => name == null ? 'Hi,' : 'Hi $name,',
    };
    final closing = tone == MessageTone.professional ? '\n\nRegards' : '';
    final bodyMessage = _ensureTerminalPunctuation(message, language);
    return '$greeting\n\n$bodyMessage$closing';
  }

  String _inferSubject(String intent, String rawMessage) {
    return switch (intent) {
      'absence' => 'Update',
      'meeting' => 'Meeting Update',
      'request' => 'Request',
      'apology' => 'Apology',
      'gratitude' => 'Thank You',
      _ => _shortSubject(rawMessage),
    };
  }

  String _shortSubject(String rawMessage) {
    final words = _normalizeSpacing(rawMessage).split(' ');
    final subject = words.take(6).join(' ');
    if (subject.isEmpty) return 'Update';
    return _capitalizeFirst(subject);
  }

  String? _firstName(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.split(RegExp(r'\s+')).first;
  }

  String _normalizeSpacing(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _capitalizeFirst(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }

  String _ensureTerminalPunctuation(String value, MessageLanguage language) {
    final trimmed = value.trimRight();
    if (trimmed.isEmpty) return trimmed;
    if (RegExp(r'[.!?।]$').hasMatch(trimmed)) return trimmed;
    return language == MessageLanguage.hindi ? '$trimmed।' : '$trimmed.';
  }
}
