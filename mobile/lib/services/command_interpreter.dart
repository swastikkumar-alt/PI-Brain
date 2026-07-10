import '../models/phone_action.dart';

class CommandInterpreter {
  const CommandInterpreter();

  Object parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      return const UnsupportedPhoneCommand('Command is empty.');
    }

    final withoutPolitePrefix = raw.replaceFirst(
      RegExp(r'^\s*(please|hey pie|pie)\s*,?\s+', caseSensitive: false),
      '',
    );

    var command = withoutPolitePrefix.trim();
    var targetApp = 'whatsapp';

    final appSuffix = RegExp(
      r'\s+(?:on|via|through)\s+(whatsapp|wa|gmail|email|mail)\s*$',
      caseSensitive: false,
    ).firstMatch(command);
    if (appSuffix != null) {
      targetApp = _normalizeTargetApp(appSuffix.group(1) ?? 'whatsapp');
      command = command.substring(0, appSuffix.start).trim();
    }

    final emailCommand = _parseEmailCommand(raw, command, targetApp);
    if (emailCommand != null) return emailCommand;

    if (_looksLikeEmailCommand(command) && targetApp != 'email') {
      targetApp = 'email';
    }

    if (targetApp == 'email') {
      final emailTargetCommand = _parseEmailCommand(raw, command, targetApp);
      if (emailTargetCommand != null) return emailTargetCommand;
    }

    final patterns = <RegExp>[
      RegExp(
        r'^(?:send\s+)?(?:a\s+)?(?:whatsapp|wa)\s+message\s+to\s+(.+?)\s+(?:that|saying|says|with)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:message|msg|text)\s+(.+?)\s+(?:that|saying|says|with)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^send\s+(?:a\s+)?message\s+to\s+(.+?)\s+(?:that|saying|says|with)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(r'^tell\s+(.+?)\s+(?:that|saying)\s+(.+)$', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(command);
      if (match == null) continue;

      final recipient = _cleanSlot(match.group(1) ?? '');
      final messageSlot = _cleanMessage(match.group(2) ?? '');
      final message = messageSlot.message;
      if (recipient.isEmpty || message.isEmpty) {
        break;
      }

      return ParsedPhoneCommand(
        type: PhoneActionType.whatsappMessage,
        rawCommand: raw,
        recipientQuery: recipient,
        messageBody: message,
        targetApp: targetApp,
        intent: _detectIntent(message),
        requestedTone: messageSlot.requestedTone,
        emailAttachmentRequested: messageSlot.attachmentRequested,
        emailAttachmentHint: messageSlot.attachmentHint,
      );
    }

    return const UnsupportedPhoneCommand(
      'I can handle WhatsApp message commands in this milestone.',
    );
  }

  String _cleanSlot(String value) {
    return value
        .trim()
        .replaceAll(RegExp(r'''^[`"']+|[`"']+$'''), '')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  _MessageSlot _cleanMessage(String value) {
    final withoutTrailingApp = value.replaceFirst(
      RegExp(
        r'\s+(?:on|via|through)\s+(whatsapp|wa|gmail|email|mail)\s*$',
        caseSensitive: false,
      ),
      '',
    );
    final normalized = _cleanSlot(withoutTrailingApp);
    final professionalPattern = RegExp(
      r'\s*(?:[,.;-]?\s*(?:and\s+)?(?:please\s+)?)?(?:formalize(?:\s+(?:it|this|the\s+message|message))?|make\s+(?:it|this|the\s+message|message)\s+(?:formal|professional)|write\s+(?:(?:it|this|the\s+message|message)\s+)?(?:formally|professionally)|in\s+(?:a\s+)?professional\s+(?:way|tone)|professionally|formally)\s*$',
      caseSensitive: false,
    );
    final friendlyPattern = RegExp(
      r'\s*(?:[,.;-]?\s*(?:and\s+)?(?:please\s+)?)?(?:make\s+(?:it|this|the\s+message|message)\s+(?:friendly|casual)|write\s+(?:(?:it|this|the\s+message|message)\s+)?(?:casually|friendly)|in\s+(?:a\s+)?friendly\s+(?:way|tone)|casually)\s*$',
      caseSensitive: false,
    );

    var requestedTone =
        RegExp(
          professionalPattern.pattern,
          caseSensitive: false,
        ).hasMatch(normalized)
        ? MessageTone.professional
        : (RegExp(
                friendlyPattern.pattern,
                caseSensitive: false,
              ).hasMatch(normalized)
              ? MessageTone.friendly
              : null);
    final attachmentPattern = RegExp(
      r'\s*(?:[,.;-]?\s*(?:and\s+)?)?(?:attach|include|add|with)\s+(?:the\s+)?(?:(?:latest|this|that)\s+)?(?:document|file|pdf|attachment)(?:\s+(?:called|named)?\s*([a-z0-9 ._()\-]+))?\s*$',
      caseSensitive: false,
    );
    final attachmentMatch = attachmentPattern.firstMatch(normalized);
    final attachmentRequested = attachmentMatch != null;
    final attachmentHint = attachmentMatch?.group(1)?.trim();

    var message = normalized
        .replaceFirst(professionalPattern, '')
        .replaceFirst(friendlyPattern, '')
        .replaceFirst(attachmentPattern, '');
    message = _cleanSlot(message)
        .replaceFirst(RegExp(r'\s+(?:and|please)$', caseSensitive: false), '')
        .trim();

    return _MessageSlot(
      message: message,
      requestedTone: requestedTone,
      attachmentRequested: attachmentRequested,
      attachmentHint: attachmentHint,
    );
  }

  ParsedPhoneCommand? _parseEmailCommand(
    String raw,
    String command,
    String targetApp,
  ) {
    final patterns = <RegExp>[
      RegExp(
        r'^(?:send\s+)?(?:an?\s+)?(?:email|mail)\s+(?:to\s+)?(.+?)\s+(?:that|saying|says|with|about)\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'^compose\s+(?:an?\s+)?(?:email|mail)\s+(?:to\s+)?(.+?)\s+(?:that|saying|says|with|about)\s+(.+)$',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(command);
      if (match == null) continue;

      final recipient = _cleanSlot(match.group(1) ?? '');
      final messageSlot = _cleanMessage(match.group(2) ?? '');
      final message = messageSlot.message;
      if (recipient.isEmpty || message.isEmpty) continue;

      return ParsedPhoneCommand(
        type: PhoneActionType.emailMessage,
        rawCommand: raw,
        recipientQuery: recipient,
        messageBody: message,
        targetApp: targetApp == 'email' ? 'email' : 'gmail',
        intent: _detectIntent(message),
        requestedTone: messageSlot.requestedTone,
        emailAttachmentRequested: messageSlot.attachmentRequested,
        emailAttachmentHint: messageSlot.attachmentHint,
      );
    }

    return null;
  }

  bool _looksLikeEmailCommand(String command) {
    return RegExp(
      r'^(?:send\s+)?(?:an?\s+)?(?:email|mail)\b',
      caseSensitive: false,
    ).hasMatch(command);
  }

  String _normalizeTargetApp(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'wa' || normalized == 'whatsapp') return 'whatsapp';
    if (normalized == 'gmail') return 'gmail';
    return 'email';
  }

  String _detectIntent(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('not coming') ||
        lower.contains("can't come") ||
        lower.contains('cannot come') ||
        lower.contains('nahi aa') ||
        lower.contains('nahin aa')) {
      return 'absence';
    }
    if (lower.contains('meeting') ||
        lower.contains('call') ||
        lower.contains('schedule') ||
        lower.contains('appointment')) {
      return 'meeting';
    }
    if (lower.contains('sorry') || lower.contains('apolog')) {
      return 'apology';
    }
    if (lower.contains('thank') || lower.contains('thanks')) {
      return 'gratitude';
    }
    if (lower.contains('?') ||
        lower.contains('please') ||
        lower.contains('can you') ||
        lower.contains('could you')) {
      return 'request';
    }
    return 'update';
  }
}

class _MessageSlot {
  const _MessageSlot({
    required this.message,
    this.requestedTone,
    this.attachmentRequested = false,
    this.attachmentHint,
  });

  final String message;
  final MessageTone? requestedTone;
  final bool attachmentRequested;
  final String? attachmentHint;
}
