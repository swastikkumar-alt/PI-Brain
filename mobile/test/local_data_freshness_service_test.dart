import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/models/entity.dart';
import 'package:pie_mobile/models/financial_transaction.dart';
import 'package:pie_mobile/services/database_service.dart';
import 'package:pie_mobile/services/local_data_freshness_service.dart';
import 'package:pie_mobile/services/native_datasource_service.dart';
import 'package:pie_mobile/services/spending_insight_service.dart';

void main() {
  test('refreshes enabled stale SMS source before spend answer', () async {
    final now = DateTime(2026, 7, 10, 12);
    final database = _FakeFreshnessDatabase(enabled: {'sms_messages'});
    final native = _FakeNativeDatasource();
    final service = LocalDataFreshnessService(
      database: database,
      nativeDatasource: native,
      spendingInsight: SpendingInsightService(database: database),
      nowProvider: () => now,
    );

    final report = await service.refreshForQuery('how much did I spend today');

    expect(native.smsImports, 1);
    expect(report.results.single.sourceId, 'sms_messages');
    expect(database.syncStates['sms_messages']?['last_success_at'], isNotNull);
  });

  test('skips fresh sources during pre-answer refresh', () async {
    final now = DateTime(2026, 7, 10, 12);
    final database = _FakeFreshnessDatabase(enabled: {'sms_messages'});
    database.syncStates['sms_messages'] = {
      'last_success_at': now
          .subtract(const Duration(minutes: 2))
          .millisecondsSinceEpoch,
    };
    final native = _FakeNativeDatasource();
    final service = LocalDataFreshnessService(
      database: database,
      nativeDatasource: native,
      spendingInsight: SpendingInsightService(database: database),
      nowProvider: () => now,
    );

    final report = await service.refreshForQuery('how much did I spend today');

    expect(native.smsImports, 0);
    expect(report.results, isEmpty);
  });

  test('does not refresh disabled sources', () async {
    final database = _FakeFreshnessDatabase(enabled: {});
    final native = _FakeNativeDatasource();
    final service = LocalDataFreshnessService(
      database: database,
      nativeDatasource: native,
      spendingInsight: SpendingInsightService(database: database),
      nowProvider: () => DateTime(2026, 7, 10, 12),
    );

    await service.refreshForQuery('how much did I spend today');

    expect(native.smsImports, 0);
    expect(database.syncStates, isEmpty);
  });
}

class _FakeNativeDatasource implements NativeDatasourceService {
  int smsImports = 0;

  @override
  Future<SmsImportResult> importRecentSms({
    int limit = 500,
    bool queueSync = false,
  }) async {
    smsImports += 1;
    return const SmsImportResult(
      imported: 2,
      skippedDuplicates: 3,
      totalRead: 5,
      nativeCursor: '1783684800000',
    );
  }

  @override
  Future<NativeImportResult> importRecentCalls({
    int limit = 500,
    bool queueSync = false,
  }) async {
    return const NativeImportResult(
      imported: 0,
      skippedDuplicates: 0,
      totalRead: 0,
    );
  }

  @override
  Future<NativeImportResult> importHealthSummary({
    int days = 30,
    bool queueSync = false,
  }) async {
    return const NativeImportResult(
      imported: 0,
      skippedDuplicates: 0,
      totalRead: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFreshnessDatabase implements DatabaseService {
  _FakeFreshnessDatabase({required this.enabled});

  final Set<String> enabled;
  final Map<String, Map<String, dynamic>> syncStates = {};

  @override
  Future<bool> isDatasourceEnabled(String sourceId) async {
    return enabled.contains(sourceId);
  }

  @override
  Future<Map<String, dynamic>?> getDatasourceSyncState(String sourceId) async {
    return syncStates[sourceId];
  }

  @override
  Future<void> markDatasourceSyncStarted({
    required String sourceId,
    required int startedAt,
    int? nextScheduledAt,
  }) async {
    syncStates[sourceId] = {
      ...?syncStates[sourceId],
      'last_started_at': startedAt,
      'next_scheduled_at': nextScheduledAt,
    };
  }

  @override
  Future<void> markDatasourceSyncSuccess({
    required String sourceId,
    required int finishedAt,
    required int totalRead,
    required int imported,
    required int skippedDuplicates,
    String? nativeCursor,
    int? nextScheduledAt,
  }) async {
    syncStates[sourceId] = {
      ...?syncStates[sourceId],
      'last_success_at': finishedAt,
      'total_read': totalRead,
      'imported': imported,
      'skipped_duplicates': skippedDuplicates,
      'last_native_cursor': nativeCursor,
      'next_scheduled_at': nextScheduledAt,
    };
  }

  @override
  Future<void> markDatasourceSyncFailure({
    required String sourceId,
    required int finishedAt,
    required String error,
    int? nextScheduledAt,
  }) async {
    syncStates[sourceId] = {
      ...?syncStates[sourceId],
      'last_error': error,
      'next_scheduled_at': nextScheduledAt,
    };
  }

  @override
  Future<List<Entity>> getEntitiesCreatedBetween({
    required int startAt,
    required int endAt,
    List<String> sourceConnectors = const [],
  }) async {
    return const [];
  }

  @override
  Future<void> upsertFinancialTransaction({
    required FinancialTransaction transaction,
    required String evidenceEntityId,
    required double confidence,
  }) async {}

  @override
  Future<SearchIndexMaintenanceResult> repairSearchIndex() async {
    return const SearchIndexMaintenanceResult(
      inserted: 0,
      updated: 0,
      deleted: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
