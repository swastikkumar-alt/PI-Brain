import '../models/entity.dart';
import 'local_data_freshness_service.dart';
import 'local_question_router.dart';

class LocalQaReportItem {
  const LocalQaReportItem({
    required this.question,
    required this.answer,
    required this.evidenceCount,
    required this.sourceBreakdown,
    required this.redactedSnippets,
  });

  final String question;
  final String answer;
  final int evidenceCount;
  final Map<String, int> sourceBreakdown;
  final List<String> redactedSnippets;
}

class LocalQaReport {
  const LocalQaReport({
    required this.generatedAt,
    required this.items,
    required this.refreshSummary,
  });

  final DateTime generatedAt;
  final List<LocalQaReportItem> items;
  final String refreshSummary;
}

class LocalQaReportService {
  LocalQaReportService({
    LocalQuestionRouter? router,
    LocalDataFreshnessService? freshness,
    DateTime Function()? nowProvider,
  }) : _router = router ?? LocalQuestionRouter(),
       _freshness = freshness ?? LocalDataFreshnessService.instance,
       _nowProvider = nowProvider ?? DateTime.now;

  final LocalQuestionRouter _router;
  final LocalDataFreshnessService _freshness;
  final DateTime Function() _nowProvider;

  Future<LocalQaReport> runRedactedReport() async {
    final refresh = await _freshness.forceRefreshAllEnabled(
      reason: 'qa_report',
    );
    final questions = <String>[
      'how much did I spend today',
      'how much did I spend on 8th July',
      'how much did I spend this month till date',
      'did I get any Amazon orders in last 48 hours',
      'how many messages did I receive yesterday',
      'did I get any important emails today',
      'missed calls from yesterday',
      'did I get spam messages today',
    ];

    final items = <LocalQaReportItem>[];
    for (final question in questions) {
      final answer = await _router.answer(question);
      final evidence = answer?.evidence ?? const <Entity>[];
      items.add(
        LocalQaReportItem(
          question: question,
          answer:
              answer?.answer ??
              'No grounded local route matched this question yet.',
          evidenceCount: evidence.length,
          sourceBreakdown: _sourceBreakdown(evidence),
          redactedSnippets: evidence
              .take(3)
              .map((entity) => _redact(entity.content ?? ''))
              .where((value) => value.isNotEmpty)
              .toList(),
        ),
      );
    }

    return LocalQaReport(
      generatedAt: _nowProvider(),
      items: items,
      refreshSummary: refresh.results.isEmpty
          ? 'No enabled local source needed refresh.'
          : refresh.results
                .map(
                  (result) =>
                      '${result.sourceId}: ${result.imported} new, ${result.skippedDuplicates} duplicates, ${result.totalRead} read${result.isBlocked ? ' (${result.blockedReason})' : ''}',
                )
                .join('\n'),
    );
  }

  Map<String, int> _sourceBreakdown(List<Entity> evidence) {
    final counts = <String, int>{};
    for (final entity in evidence) {
      final source = entity.sourceConnector ?? 'unknown';
      counts[source] = (counts[source] ?? 0) + 1;
    }
    return counts;
  }

  String _redact(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(r'\b\d{10,}\b'),
          (match) => '${match.group(0)!.substring(0, 4)}...redacted',
        )
        .replaceAllMapped(
          RegExp(r'\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b', caseSensitive: false),
          (_) => 'email...redacted',
        )
        .trim();
  }
}
