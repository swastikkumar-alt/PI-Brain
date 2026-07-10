import 'dart:async';
import 'dart:developer' as developer;

import 'database_service.dart';
import 'native_datasource_service.dart';
import 'spending_insight_service.dart';

class LocalSourceRefreshResult {
  const LocalSourceRefreshResult({
    required this.sourceId,
    required this.imported,
    required this.skippedDuplicates,
    required this.totalRead,
    this.blockedReason,
  });

  final String sourceId;
  final int imported;
  final int skippedDuplicates;
  final int totalRead;
  final String? blockedReason;

  bool get isBlocked => blockedReason != null && blockedReason!.isNotEmpty;
}

class LocalFreshnessReport {
  const LocalFreshnessReport({required this.results});

  final List<LocalSourceRefreshResult> results;

  bool get hasBlockedSources => results.any((result) => result.isBlocked);
}

class LocalDataFreshnessService {
  LocalDataFreshnessService({
    DatabaseService? database,
    NativeDatasourceService? nativeDatasource,
    SpendingInsightService? spendingInsight,
    DateTime Function()? nowProvider,
  }) : _database = database ?? DatabaseService.instance,
       _nativeDatasource = nativeDatasource ?? NativeDatasourceService.instance,
       _spendingInsight = spendingInsight ?? SpendingInsightService(),
       _nowProvider = nowProvider ?? DateTime.now;

  static final LocalDataFreshnessService instance = LocalDataFreshnessService();

  static const refreshInterval = Duration(hours: 4);
  static const preAnswerStaleAfter = Duration(minutes: 15);

  final DatabaseService _database;
  final NativeDatasourceService _nativeDatasource;
  final SpendingInsightService _spendingInsight;
  final DateTime Function() _nowProvider;
  Timer? _timer;
  bool _isRefreshing = false;

  void startForegroundScheduler() {
    _timer ??= Timer.periodic(refreshInterval, (_) {
      refreshAllEnabledIfStale(reason: 'timer');
    });
  }

  void stopForegroundScheduler() {
    _timer?.cancel();
    _timer = null;
  }

  Future<LocalFreshnessReport> refreshForQuery(String query) async {
    final sources = _sourcesForQuery(query);
    if (sources.isEmpty) return const LocalFreshnessReport(results: []);
    return _refreshSourcesIfStale(
      sources,
      staleAfter: preAnswerStaleAfter,
      reason: 'pre_answer',
    );
  }

  Future<LocalFreshnessReport> refreshAllEnabledIfStale({
    String reason = 'scheduled',
  }) {
    return _refreshSourcesIfStale(
      const ['sms_messages', 'call_logs', 'health_connect'],
      staleAfter: refreshInterval,
      reason: reason,
    );
  }

  Future<LocalFreshnessReport> forceRefreshAllEnabled({
    String reason = 'manual',
  }) {
    return _refreshSourcesIfStale(
      const ['sms_messages', 'call_logs', 'health_connect'],
      staleAfter: Duration.zero,
      reason: reason,
    );
  }

  Future<LocalFreshnessReport> _refreshSourcesIfStale(
    List<String> sourceIds, {
    required Duration staleAfter,
    required String reason,
  }) async {
    if (_isRefreshing) return const LocalFreshnessReport(results: []);
    _isRefreshing = true;
    final results = <LocalSourceRefreshResult>[];
    try {
      for (final sourceId in sourceIds.toSet()) {
        if (!await _database.isDatasourceEnabled(sourceId)) continue;
        if (!await _isStale(sourceId, staleAfter)) continue;
        results.add(await _refreshSource(sourceId, reason: reason));
      }
      await _spendingInsight.backfillLedger();
      await _database.repairSearchIndex();
    } catch (error, stackTrace) {
      developer.log(
        'Local freshness refresh failed.',
        name: 'LocalDataFreshnessService',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isRefreshing = false;
    }
    return LocalFreshnessReport(results: results);
  }

  Future<bool> _isStale(String sourceId, Duration staleAfter) async {
    if (staleAfter == Duration.zero) return true;
    final state = await _database.getDatasourceSyncState(sourceId);
    final lastSuccess = (state?['last_success_at'] as num?)?.toInt();
    if (lastSuccess == null || lastSuccess <= 0) return true;
    final age = _nowProvider().millisecondsSinceEpoch - lastSuccess;
    return age >= staleAfter.inMilliseconds;
  }

  Future<LocalSourceRefreshResult> _refreshSource(
    String sourceId, {
    required String reason,
  }) async {
    final startedAt = _nowProvider().millisecondsSinceEpoch;
    final nextScheduledAt = startedAt + refreshInterval.inMilliseconds;
    await _database.markDatasourceSyncStarted(
      sourceId: sourceId,
      startedAt: startedAt,
      nextScheduledAt: nextScheduledAt,
    );

    try {
      final result = switch (sourceId) {
        'sms_messages' => await _nativeDatasource.importRecentSms(
          limit: 2000,
          queueSync: false,
        ),
        'call_logs' => await _nativeDatasource.importRecentCalls(
          limit: 1000,
          queueSync: false,
        ),
        'health_connect' => await _nativeDatasource.importHealthSummary(
          days: 45,
          queueSync: false,
        ),
        _ => const NativeImportResult(
          imported: 0,
          skippedDuplicates: 0,
          totalRead: 0,
          blockedReason: 'Unsupported local source.',
        ),
      };

      final finishedAt = _nowProvider().millisecondsSinceEpoch;
      if (result.isBlocked) {
        await _database.markDatasourceSyncFailure(
          sourceId: sourceId,
          finishedAt: finishedAt,
          error: result.blockedReason!,
          nextScheduledAt: nextScheduledAt,
        );
      } else {
        await _database.markDatasourceSyncSuccess(
          sourceId: sourceId,
          finishedAt: finishedAt,
          totalRead: result.totalRead,
          imported: result.imported,
          skippedDuplicates: result.skippedDuplicates,
          nativeCursor: result.nativeCursor,
          nextScheduledAt: nextScheduledAt,
        );
      }
      return LocalSourceRefreshResult(
        sourceId: sourceId,
        imported: result.imported,
        skippedDuplicates: result.skippedDuplicates,
        totalRead: result.totalRead,
        blockedReason: result.blockedReason,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to refresh $sourceId during $reason.',
        name: 'LocalDataFreshnessService',
        error: error,
        stackTrace: stackTrace,
      );
      final finishedAt = _nowProvider().millisecondsSinceEpoch;
      await _database.markDatasourceSyncFailure(
        sourceId: sourceId,
        finishedAt: finishedAt,
        error: error.toString(),
        nextScheduledAt: nextScheduledAt,
      );
      return LocalSourceRefreshResult(
        sourceId: sourceId,
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: error.toString(),
      );
    }
  }

  List<String> _sourcesForQuery(String query) {
    final lower = query.toLowerCase();
    final sources = <String>{};
    if (RegExp(
      r'\b(spend|spent|expense|expenses|paid|payment|kharcha|kharch|order|orders|package|parcel|shipment|delivery|amazon|flipkart|sms|message|messages|spam)\b',
    ).hasMatch(lower)) {
      sources.add('sms_messages');
    }
    if (RegExp(
      r'\b(call|calls|missed|unanswered|spam call)\b',
    ).hasMatch(lower)) {
      sources.add('call_logs');
    }
    if (RegExp(r'\b(step|steps|sleep|slept|asleep|health)\b').hasMatch(lower)) {
      sources.add('health_connect');
    }
    return sources.toList();
  }
}
