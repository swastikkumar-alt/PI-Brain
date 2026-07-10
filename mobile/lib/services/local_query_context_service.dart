import 'package:intl/intl.dart';

import '../models/entity.dart';
import '../models/message.dart';
import 'agent_prompt_policy.dart';
import 'database_service.dart';
import 'query_date_range_resolver.dart';

class LocalQueryContextResult {
  const LocalQueryContextResult({
    required this.requiresLocalGrounding,
    required this.contextText,
    required this.evidence,
    required this.citations,
    this.noEvidenceAnswer,
  });

  final bool requiresLocalGrounding;
  final String contextText;
  final List<Entity> evidence;
  final List<Citation> citations;
  final String? noEvidenceAnswer;
}

class LocalQueryContextService {
  LocalQueryContextService({
    DatabaseService? database,
    AgentPromptPolicy? promptPolicy,
    QueryDateRangeResolver? dateRangeResolver,
  }) : _database = database ?? DatabaseService.instance,
       _promptPolicy = promptPolicy ?? const AgentPromptPolicy(),
       _dateRangeResolver = dateRangeResolver ?? const QueryDateRangeResolver();

  final DatabaseService _database;
  final AgentPromptPolicy _promptPolicy;
  final QueryDateRangeResolver _dateRangeResolver;

  static const _allLocalSources = <String>[
    'SMS',
    'GMAIL',
    'NOTIFICATION',
    'PAYMENT',
    'CHAT',
    'PDF',
    'HEALTH',
  ];

  Future<LocalQueryContextResult> build(String userMessage) async {
    await _database.ensureSearchIndexFresh();

    final requiresLocalGrounding = _promptPolicy.requiresLocalGrounding(
      userMessage,
    );
    final dateRange = _dateRangeResolver.tryResolve(userMessage);
    final sourceConnectors = _inferSourceConnectors(userMessage);
    final evidenceById = <String, Entity>{};

    final searchEvidence = await _database.searchEntitiesForQuery(
      userMessage,
      sourceConnectors: sourceConnectors,
      startAt: dateRange?.start.millisecondsSinceEpoch,
      endAt: dateRange?.end.millisecondsSinceEpoch,
      limit: 30,
    );
    for (final entity in searchEvidence) {
      evidenceById[entity.id] = entity;
    }

    if (requiresLocalGrounding &&
        dateRange != null &&
        evidenceById.length < 8) {
      final rangeEvidence = await _database.getEntitiesCreatedBetween(
        startAt: dateRange.start.millisecondsSinceEpoch,
        endAt: dateRange.end.millisecondsSinceEpoch,
        sourceConnectors: sourceConnectors.isEmpty
            ? _allLocalSources
            : sourceConnectors,
      );
      for (final entity in rangeEvidence.take(60)) {
        evidenceById[entity.id] = entity;
      }
    }

    final evidence = evidenceById.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final visibleEvidence = evidence.take(30).toList();
    final citations = <Citation>[
      for (var index = 0; index < visibleEvidence.length; index++)
        Citation(
          documentId: visibleEvidence[index].id,
          title:
              'Local evidence (${visibleEvidence[index].sourceConnector ?? 'unknown'})',
          chunkIndex: index,
        ),
    ];

    return LocalQueryContextResult(
      requiresLocalGrounding: requiresLocalGrounding,
      evidence: visibleEvidence,
      citations: citations,
      contextText: _buildContextText(userMessage, visibleEvidence, dateRange),
      noEvidenceAnswer: requiresLocalGrounding && visibleEvidence.isEmpty
          ? _buildNoEvidenceAnswer(dateRange, sourceConnectors)
          : null,
    );
  }

  List<String> _inferSourceConnectors(String query) {
    final lower = query.toLowerCase();
    final sources = <String>{};

    if (_hasAny(lower, const [
      'spend',
      'spent',
      'expense',
      'payment',
      'paid',
      'bank',
      'transaction',
      'upi',
      'order',
      'package',
      'delivery',
      'shipment',
    ])) {
      sources.addAll(const ['SMS', 'GMAIL', 'NOTIFICATION', 'PAYMENT']);
    }

    if (_hasAny(lower, const ['sms', 'message', 'messages', 'spam'])) {
      sources.addAll(const ['SMS', 'NOTIFICATION']);
    }

    if (_hasAny(lower, const ['gmail', 'email', 'mail'])) {
      sources.add('GMAIL');
    }

    if (_hasAny(lower, const ['whatsapp', 'chat'])) {
      sources.add('CHAT');
    }

    if (_hasAny(lower, const ['file', 'files', 'pdf', 'document', 'cabinet'])) {
      sources.add('PDF');
    }

    if (_hasAny(lower, const ['health', 'steps', 'sleep'])) {
      sources.add('HEALTH');
    }

    if (sources.isEmpty && _promptPolicy.requiresLocalGrounding(query)) {
      sources.addAll(_allLocalSources);
    }

    return sources.toList(growable: false);
  }

  String _buildContextText(
    String userMessage,
    List<Entity> evidence,
    QueryDateRange? dateRange,
  ) {
    final buffer = StringBuffer()
      ..writeln('=== RETRIEVED LOCAL EVIDENCE ===')
      ..writeln('User query: $userMessage');
    if (dateRange != null) {
      buffer.writeln('Date filter: ${dateRange.displayLabel}');
    }
    buffer.writeln('Evidence count: ${evidence.length}');

    if (evidence.isEmpty) {
      buffer.writeln('No matching local evidence was found.');
      return buffer.toString();
    }

    for (var index = 0; index < evidence.length; index++) {
      final entity = evidence[index];
      buffer
        ..writeln()
        ..writeln(
          '[${index + 1}] id=${entity.id} source=${entity.sourceConnector ?? 'unknown'} type=${entity.entityType} time=${_formatTime(entity.createdAt)}',
        )
        ..writeln(_truncate(entity.content ?? '', 1200));
    }

    return buffer.toString();
  }

  String _buildNoEvidenceAnswer(
    QueryDateRange? dateRange,
    List<String> sourceConnectors,
  ) {
    final sourceText = sourceConnectors.isEmpty
        ? 'local sources'
        : sourceConnectors.join(', ');
    final rangeText = dateRange == null ? '' : ' for ${dateRange.displayLabel}';
    return 'I do not have enough synced local evidence to answer that$rangeText. I checked $sourceText. Connect or sync the relevant source, then ask again.';
  }

  String _formatTime(int millis) {
    return DateFormat(
      'd MMM yyyy, HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  String _truncate(String value, int maxChars) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) return normalized;
    return '${normalized.substring(0, maxChars)}...';
  }

  bool _hasAny(String haystack, List<String> needles) {
    return needles.any(haystack.contains);
  }
}
