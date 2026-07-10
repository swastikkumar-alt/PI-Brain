enum AgentResponseMode { generalAssistant, localGrounded }

class AgentPromptPolicy {
  const AgentPromptPolicy();

  AgentResponseMode modeFor(String userMessage) {
    return requiresLocalGrounding(userMessage)
        ? AgentResponseMode.localGrounded
        : AgentResponseMode.generalAssistant;
  }

  bool requiresLocalGrounding(String userMessage) {
    final normalized = _normalize(userMessage);
    if (normalized.isEmpty) return false;

    final isMessageSendCommand =
        _hasAny(normalized, const ['message ', 'send ', 'whatsapp ']) &&
        _hasAny(normalized, const [' that ', ' to ', ' on whatsapp']);
    if (isMessageSendCommand) return false;

    final localDataNouns = <String>[
      'bank',
      'cabinet',
      'call',
      'calls',
      'contact',
      'contacts',
      'delivery',
      'document',
      'documents',
      'expense',
      'expenses',
      'file',
      'files',
      'gmail',
      'health',
      'installed app',
      'local link',
      'local links',
      'message',
      'messages',
      'notification',
      'notifications',
      'order',
      'orders',
      'package',
      'packages',
      'payment',
      'payments',
      'pdf',
      'phone',
      'sleep',
      'sms',
      'spam',
      'spend',
      'spent',
      'steps',
      'synced',
      'transaction',
      'transactions',
      'upi',
      'whatsapp context',
    ];

    final personalMarkers = <String>[
      ' my ',
      ' me ',
      ' i ',
      ' did i ',
      ' do i ',
      ' have i ',
      ' yesterday',
      ' today',
      ' last ',
      ' in my ',
      ' on my ',
      ' from my ',
    ];

    if (_hasAny(normalized, localDataNouns) &&
        _hasAny(' $normalized ', personalMarkers)) {
      return true;
    }

    final directLocalRequests = <String>[
      'how much did i spend',
      'how much did i spent',
      'what did i spend',
      'did i get any order',
      'did i get any package',
      'do i got any order',
      'do i got any package',
      'spam calls',
      'spam messages',
      'block those messages',
      'read my sms',
      'read my messages',
      'read my notifications',
      'read my gmail',
      'read my files',
      'local memory',
      'local files',
      'local links',
      'missed calls',
      'unanswered calls',
      'important emails',
      'how many messages',
      'steps every day',
      'sleep better',
      'when was i asleep',
      'at what time was i asleep',
      'synced files',
    ];

    return _hasAny(normalized, directLocalRequests);
  }

  String buildSystemPrompt({
    required String userMessage,
    required String retrievedContext,
    required String fileContext,
  }) {
    final mode = modeFor(userMessage);
    final context = retrievedContext.trim().isEmpty
        ? 'No retrieved local context was available.'
        : retrievedContext.trim();
    final attachedContext = fileContext.trim();

    if (mode == AgentResponseMode.localGrounded) {
      return '''
You are the local-data reasoning core for the Personal Intelligence Engine (PIE).
Answer only from the numbered retrieved local evidence, memory files, or attached file content.
Do not invent phone-local facts, transactions, messages, orders, contacts, health data, or app data.
If the evidence does not contain the requested fact, say that the synced evidence is insufficient and name the missing source.
For totals, counts, dates, and status checks, use only values present in the evidence. Do not estimate or fill gaps.
Keep the answer concise and mention the source type when it matters.

Retrieved Local Context:
$context
${attachedContext.isEmpty ? '' : '\nAttached File Context:\n$attachedContext'}
''';
    }

    return '''
You are PIE, a private phone intelligence assistant.
Answer the user's question directly and professionally.
Use retrieved local context only when it is relevant, and treat it as optional background.
Do not claim to know phone-local facts unless the supplied context supports them.
For general questions, drafting, explanation, planning, rewriting, coding, or translation, answer normally without requiring retrieved device context.

Optional Local Context:
$context
${attachedContext.isEmpty ? '' : '\nAttached File Context:\n$attachedContext'}
''';
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9@+._\s-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _hasAny(String haystack, List<String> needles) {
    return needles.any(haystack.contains);
  }
}
