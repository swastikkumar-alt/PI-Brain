import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/entity.dart';
import '../models/financial_transaction.dart';
import 'database_service.dart';
import 'query_date_range_resolver.dart';

class SpendingDateRange {
  const SpendingDateRange({
    required this.label,
    required this.start,
    required this.end,
  });

  final String label;
  final DateTime start;
  final DateTime end;
}

class SpendingTransaction {
  const SpendingTransaction({
    required this.entityId,
    required this.amount,
    required this.amountMinor,
    required this.currencySymbol,
    required this.sourceConnector,
    required this.evidence,
    required this.timestamp,
    required this.canonicalKey,
    this.merchant,
    this.reference,
  });

  final String entityId;
  final double amount;
  final int amountMinor;
  final String currencySymbol;
  final String sourceConnector;
  final String evidence;
  final int timestamp;
  final String canonicalKey;
  final String? merchant;
  final String? reference;
}

class SpendingInsightResult {
  const SpendingInsightResult({
    required this.answer,
    required this.range,
    required this.transactions,
  });

  final String answer;
  final SpendingDateRange range;
  final List<SpendingTransaction> transactions;
}

class SpendingLedgerBackfillResult {
  const SpendingLedgerBackfillResult({
    required this.scannedEntities,
    required this.indexedTransactions,
  });

  final int scannedEntities;
  final int indexedTransactions;
}

class SpendingInsightService {
  SpendingInsightService({
    DatabaseService? database,
    DateTime Function()? nowProvider,
    QueryDateRangeResolver? dateRangeResolver,
  }) : _database = database ?? DatabaseService.instance,
       _nowProvider = nowProvider ?? DateTime.now,
       _dateRangeResolver = dateRangeResolver ?? const QueryDateRangeResolver();

  final DatabaseService _database;
  final DateTime Function() _nowProvider;
  final QueryDateRangeResolver _dateRangeResolver;

  static final _amountPattern = RegExp(
    '(?:\\u20B9|rs\\.?|inr)[ \\t]*([0-9][0-9,]*(?:\\.\\d{1,2})?)|'
    '([0-9][0-9,]*(?:\\.\\d{1,2})?)[ \\t]*(?:\\u20B9|rs\\.?|inr)',
    caseSensitive: false,
  );

  static final _debitPattern = RegExp(
    r'\b(?:debited|debit|spent|paid|payment|purchase|purchased|withdrawn|deducted|sent|transferred|upi|imps|neft|pos|card|dr)\b',
    caseSensitive: false,
  );

  static final _creditPattern = RegExp(
    r'\b(?:credited|credit|received|refund|refunded|cashback|reversal|reversed|deposited|added|cr)\b',
    caseSensitive: false,
  );

  static final _failedPattern = RegExp(
    r'\b(?:failed|declined|unsuccessful|cancelled|canceled|pending|request|otp)\b',
    caseSensitive: false,
  );

  static final _referencePattern = RegExp(
    r'\b(?:upi\s+ref(?:erence)?|utr|txn(?:\s*id)?|transaction\s*id|ref(?:\s*no\.?)?)[:\s-]*([a-z0-9]{6,})',
    caseSensitive: false,
  );

  static final _merchantPatterns = <RegExp>[
    RegExp(
      r'\b(?:to|at|for)\s+([a-z0-9][a-z0-9 .&@_-]{1,48}?)(?:\s+(?:on|via|using|upi|ref|txn|from|with|\.|,)|$)',
      caseSensitive: false,
    ),
    RegExp(
      r'\bmerchant\s+([a-z0-9][a-z0-9 .&@_-]{1,48}?)(?:\s+(?:on|via|ref|txn|\.|,)|$)',
      caseSensitive: false,
    ),
  ];

  static final _balancePattern = RegExp(
    r'\b(?:available|avl|avail|closing|current)\s+(?:balance|bal)\b|\bbal(?:ance)?\s*(?:is|:)?\b',
    caseSensitive: false,
  );

  bool canHandle(String query) {
    return _hasSpendIntent(query);
  }

  Future<SpendingInsightResult?> answerIfSupported(String query) async {
    if (!_hasSpendIntent(query)) return null;

    final range = tryResolveRange(query, now: _nowProvider());
    if (range == null) {
      return SpendingInsightResult(
        answer:
            'Tell me the period to calculate spend, for example: "how much did I spend today", "yesterday", "on 8 July", or "this month till date". I will only count synced SMS, Gmail, and payment notification evidence.',
        range: _todayRange(_nowProvider()),
        transactions: const [],
      );
    }

    final backfill = await backfillLedger(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
    );
    final ledgerRows = await _database
        .getFinancialTransactionsWithEvidenceBetween(
          startAt: range.start.millisecondsSinceEpoch,
          endAt: range.end.millisecondsSinceEpoch,
        );
    final transactions =
        ledgerRows
            .map(_transactionFromLedgerRow)
            .whereType<SpendingTransaction>()
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final answer = transactions.isEmpty
        ? _buildNoDataAnswerFromLedger(range, backfill.scannedEntities)
        : _buildSpendAnswer(range, transactions);
    return SpendingInsightResult(
      answer: answer,
      range: range,
      transactions: transactions,
    );
  }

  Future<SpendingLedgerBackfillResult> backfillLedger({
    int? startAt,
    int? endAt,
  }) async {
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: startAt ?? 0,
      endAt: endAt ?? DateTime.now().millisecondsSinceEpoch,
      sourceConnectors: const ['SMS', 'GMAIL', 'NOTIFICATION', 'PAYMENT'],
    );
    final transactions = _dedupeTransactions(
      entities.map(parseTransaction).whereType<SpendingTransaction>().toList(),
    );
    await _recordLedger(transactions);
    return SpendingLedgerBackfillResult(
      scannedEntities: entities.length,
      indexedTransactions: transactions.length,
    );
  }

  SpendingDateRange resolveRange(String query, {DateTime? now}) {
    return tryResolveRange(query, now: now) ??
        _todayRange(now ?? _nowProvider());
  }

  SpendingDateRange? tryResolveRange(String query, {DateTime? now}) {
    final base = now ?? _nowProvider();
    final resolved = _dateRangeResolver.tryResolve(query, now: base);
    if (resolved == null) return null;
    return SpendingDateRange(
      label: resolved.label,
      start: resolved.start,
      end: resolved.end,
    );
  }

  SpendingInsightResult buildResult({
    required String query,
    required SpendingDateRange range,
    required List<Entity> entities,
  }) {
    final transactions = _dedupeTransactions(
      entities.map(parseTransaction).whereType<SpendingTransaction>().toList(),
    )..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final answer = transactions.isEmpty
        ? _buildNoDataAnswer(range, entities)
        : _buildSpendAnswer(range, transactions);

    return SpendingInsightResult(
      answer: answer,
      range: range,
      transactions: transactions,
    );
  }

  SpendingTransaction? parseTransaction(Entity entity) {
    final rawContent = entity.content?.trim() ?? '';
    final content = _transactionBody(rawContent);
    if (content.isEmpty || !_amountPattern.hasMatch(content)) return null;

    final lower = content.toLowerCase();
    if (_failedPattern.hasMatch(lower)) return null;
    if (_creditPattern.hasMatch(lower) && !_debitPattern.hasMatch(lower)) {
      return null;
    }

    for (final match in _amountPattern.allMatches(content)) {
      final rawAmount = match.group(1) ?? match.group(2);
      final amount = _parseAmount(rawAmount);
      if (amount == null || amount <= 0) continue;
      final amountMinor = (amount * 100).round();

      final start = (match.start - 90).clamp(0, content.length);
      final end = (match.end + 90).clamp(0, content.length);
      final window = content.substring(start, end);
      final windowLower = window.toLowerCase();

      if (_failedPattern.hasMatch(windowLower)) continue;
      if (_looksLikeBalanceAmount(content, match)) continue;
      if (_creditPattern.hasMatch(windowLower) &&
          !_debitPattern.hasMatch(windowLower)) {
        continue;
      }
      if (!_debitPattern.hasMatch(windowLower) &&
          !_debitPattern.hasMatch(lower)) {
        continue;
      }

      final merchant = _extractMerchant(content);
      final reference = _extractReference(content);
      final timestamp = _transactionTimestamp(entity, rawContent);
      final canonicalKey = _canonicalTransactionKey(
        amountMinor: amountMinor,
        merchant: merchant,
        reference: reference,
        timestamp: timestamp,
        evidence: content,
      );

      return SpendingTransaction(
        entityId: entity.id,
        amount: amount,
        amountMinor: amountMinor,
        currencySymbol: '\u20B9',
        sourceConnector: entity.sourceConnector ?? 'unknown',
        evidence: _snippet(rawContent),
        timestamp: timestamp,
        canonicalKey: canonicalKey,
        merchant: merchant,
        reference: reference,
      );
    }

    return null;
  }

  SpendingTransaction? _transactionFromLedgerRow(Map<String, dynamic> row) {
    final amountMinor = (row['amount_minor'] as num?)?.toInt();
    final occurredAt = (row['occurred_at'] as num?)?.toInt();
    if (amountMinor == null || amountMinor <= 0 || occurredAt == null) {
      return null;
    }
    final entityId = row['entity_id']?.toString();
    return SpendingTransaction(
      entityId: entityId == null || entityId.isEmpty
          ? row['id']?.toString() ?? ''
          : entityId,
      amount: amountMinor / 100,
      amountMinor: amountMinor,
      currencySymbol: '\u20B9',
      sourceConnector: row['source_connector']?.toString() ?? 'unknown',
      evidence: _snippet(row['evidence_content']?.toString() ?? ''),
      timestamp: occurredAt,
      canonicalKey: row['canonical_key']?.toString() ?? '',
      merchant: row['merchant']?.toString(),
      reference: row['reference']?.toString(),
    );
  }

  List<SpendingTransaction> _dedupeTransactions(
    List<SpendingTransaction> transactions,
  ) {
    final sorted = [...transactions]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final deduped = <SpendingTransaction>[];

    for (final transaction in sorted) {
      final existingIndex = deduped.indexWhere(
        (candidate) => _isLikelySameTransaction(candidate, transaction),
      );
      if (existingIndex == -1) {
        deduped.add(transaction);
        continue;
      }

      final existing = deduped[existingIndex];
      if (_evidenceQuality(transaction) > _evidenceQuality(existing)) {
        deduped[existingIndex] = transaction;
      }
    }
    return deduped;
  }

  bool _isLikelySameTransaction(
    SpendingTransaction left,
    SpendingTransaction right,
  ) {
    final leftRef = left.reference?.toLowerCase();
    final rightRef = right.reference?.toLowerCase();
    if (leftRef != null &&
        leftRef.isNotEmpty &&
        rightRef != null &&
        rightRef.isNotEmpty) {
      return leftRef == rightRef;
    }

    if (left.amountMinor != right.amountMinor) return false;
    if (!_sameLocalDay(left.timestamp, right.timestamp)) return false;

    final leftMerchant = _normalizeMerchant(left.merchant);
    final rightMerchant = _normalizeMerchant(right.merchant);
    final merchantCompatible =
        leftMerchant.isEmpty ||
        rightMerchant.isEmpty ||
        leftMerchant == rightMerchant;
    final timeGap = (left.timestamp - right.timestamp).abs();

    if (merchantCompatible &&
        timeGap <= const Duration(hours: 6).inMilliseconds) {
      return true;
    }

    return _tokenOverlap(left.evidence, right.evidence) >= 0.58 &&
        timeGap <= const Duration(hours: 12).inMilliseconds;
  }

  String _buildSpendAnswer(
    SpendingDateRange range,
    List<SpendingTransaction> transactions,
  ) {
    final total = transactions.fold<double>(
      0,
      (sum, transaction) => sum + transaction.amount,
    );
    final dateLabel = _rangeLabel(range);
    final buffer = StringBuffer()
      ..writeln(
        'For $dateLabel, I found ${transactions.length} spending transaction${transactions.length == 1 ? '' : 's'} in your synced local data.',
      )
      ..writeln()
      ..writeln('**Total spent: ${_formatCurrency(total)}**');

    final topTransactions = [...transactions]
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final visible = topTransactions.take(5).toList();
    if (visible.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Largest items:');
      for (final transaction in visible) {
        final merchant = transaction.merchant == null
            ? ''
            : ' - ${transaction.merchant}';
        buffer.writeln('- ${_formatCurrency(transaction.amount)}$merchant');
      }
    }

    final projection = _monthlyProjection(range, transactions);
    if (projection != null) {
      buffer
        ..writeln()
        ..writeln(
          'Projected full-month spend at the current daily pace: ${_formatCurrency(projection)}.',
        );
    }

    buffer
      ..writeln()
      ..write(
        'I counted only debit/payment evidence and excluded credits, refunds, cashback, OTP, pending, and failed transaction messages.',
      );

    return buffer.toString();
  }

  String _buildNoDataAnswer(SpendingDateRange range, List<Entity> entities) {
    final dateLabel = _rangeLabel(range);
    if (entities.isEmpty) {
      return 'I could not calculate spend for $dateLabel because no SMS, Gmail, or payment notification data is synced locally for that period. Turn on SMS Messages and payment/bank notifications in Choose what PIE can read, run SMS import, then ask again.';
    }

    return 'I checked ${entities.length} synced local item${entities.length == 1 ? '' : 's'} for $dateLabel, but found no debit/payment transaction evidence. I did not count credits, refunds, cashback, OTP, pending, or failed transaction messages.';
  }

  String _buildNoDataAnswerFromLedger(
    SpendingDateRange range,
    int scannedEntities,
  ) {
    final dateLabel = _rangeLabel(range);
    if (scannedEntities == 0) {
      return 'I could not calculate spend for $dateLabel because no SMS, Gmail, or payment notification data is synced locally for that period. PIE now refreshes enabled local sources before answering; turn on SMS Messages and notification access, then ask again.';
    }

    return 'I checked $scannedEntities synced local item${scannedEntities == 1 ? '' : 's'} for $dateLabel and updated the spend ledger, but found no debit/payment transaction evidence. I did not count credits, refunds, cashback, OTP, pending, failed, or balance-only messages.';
  }

  SpendingDateRange _todayRange(DateTime base) {
    final today = DateTime(base.year, base.month, base.day);
    return SpendingDateRange(
      label: 'today',
      start: today,
      end: today.add(const Duration(days: 1)),
    );
  }

  double? _parseAmount(String? value) {
    if (value == null) return null;
    return double.tryParse(value.replaceAll(',', '').trim());
  }

  bool _looksLikeBalanceAmount(String content, RegExpMatch amountMatch) {
    final beforeStart = (amountMatch.start - 40).clamp(0, content.length);
    final afterEnd = (amountMatch.end + 40).clamp(0, content.length);
    final before = content.substring(beforeStart, amountMatch.start);
    final after = content.substring(amountMatch.end, afterEnd);
    final around = '$before ${amountMatch.group(0) ?? ''} $after';
    if (!_balancePattern.hasMatch(around)) return false;

    final actionWindowStart = (amountMatch.start - 80).clamp(0, content.length);
    final actionWindowEnd = (amountMatch.end + 80).clamp(0, content.length);
    final actionWindow = content.substring(actionWindowStart, actionWindowEnd);
    return !_debitPattern.hasMatch(actionWindow);
  }

  Future<void> _recordLedger(List<SpendingTransaction> transactions) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final transaction in transactions) {
      await _database.upsertFinancialTransaction(
        transaction: FinancialTransaction(
          id: _ledgerId(transaction.canonicalKey),
          canonicalKey: transaction.canonicalKey,
          direction: 'debit',
          amountMinor: transaction.amountMinor,
          currency: 'INR',
          occurredAt: transaction.timestamp,
          sourceConnector: transaction.sourceConnector,
          merchant: transaction.merchant,
          reference: transaction.reference,
          createdAt: transaction.timestamp,
          updatedAt: now,
        ),
        evidenceEntityId: transaction.entityId,
        confidence: 1,
      );
    }
  }

  String _transactionBody(String content) {
    final split = content.split(RegExp(r'\r?\n\r?\n'));
    if (split.length > 1 &&
        RegExp(
          r'^(received|sent)\s+sms|^notification from',
          caseSensitive: false,
        ).hasMatch(split.first.trim())) {
      return split.sublist(1).join('\n\n').trim();
    }
    return content.trim();
  }

  int _transactionTimestamp(Entity entity, String content) {
    final dateMatch = RegExp(
      r'^Date:\s*(\d{12,})\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(content);
    final parsed = int.tryParse(dateMatch?.group(1) ?? '');
    return parsed ?? entity.createdAt;
  }

  String _canonicalTransactionKey({
    required int amountMinor,
    required int timestamp,
    required String evidence,
    String? merchant,
    String? reference,
  }) {
    final ref = reference?.trim().toLowerCase();
    if (ref != null && ref.isNotEmpty) return 'ref:$ref';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final day =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final normalizedMerchant = _normalizeMerchant(merchant);
    final fallbackMerchant = normalizedMerchant.isNotEmpty
        ? normalizedMerchant
        : _stableEvidenceTokens(evidence).take(6).join(' ');
    return 'amt:$amountMinor|day:$day|merchant:$fallbackMerchant';
  }

  String _ledgerId(String canonicalKey) {
    final encoded = base64UrlEncode(
      utf8.encode(canonicalKey),
    ).replaceAll('=', '');
    final length = encoded.length < 40 ? encoded.length : 40;
    return 'fin_${encoded.substring(0, length)}';
  }

  String _normalizeMerchant(String? merchant) {
    return (merchant ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  bool _sameLocalDay(int left, int right) {
    final l = DateTime.fromMillisecondsSinceEpoch(left);
    final r = DateTime.fromMillisecondsSinceEpoch(right);
    return l.year == r.year && l.month == r.month && l.day == r.day;
  }

  int _evidenceQuality(SpendingTransaction transaction) {
    var score = transaction.evidence.length;
    if (transaction.reference?.isNotEmpty == true) score += 500;
    if (transaction.merchant?.isNotEmpty == true) score += 200;
    if (transaction.sourceConnector == 'SMS') score += 50;
    return score;
  }

  double _tokenOverlap(String left, String right) {
    final leftTokens = _stableEvidenceTokens(left).toSet();
    final rightTokens = _stableEvidenceTokens(right).toSet();
    if (leftTokens.isEmpty || rightTokens.isEmpty) return 0;
    final intersection = leftTokens.intersection(rightTokens).length;
    final union = leftTokens.union(rightTokens).length;
    return intersection / union;
  }

  List<String> _stableEvidenceTokens(String value) {
    const ignored = {
      'received',
      'sent',
      'sms',
      'from',
      'date',
      'notification',
      'your',
      'account',
      'payment',
      'paid',
      'debited',
      'inr',
      'rs',
    };
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((token) => token.length >= 3 && !ignored.contains(token))
        .toList();
  }

  double? _monthlyProjection(
    SpendingDateRange range,
    List<SpendingTransaction> transactions,
  ) {
    if (transactions.isEmpty) return null;
    if (range.start.day != 1 ||
        range.start.month !=
            range.end.subtract(const Duration(days: 1)).month) {
      return null;
    }
    final daysElapsed = range.end.difference(range.start).inDays.clamp(1, 31);
    final daysInMonth = DateTime(
      range.start.year,
      range.start.month + 1,
      0,
    ).day;
    final total = transactions.fold<double>(
      0,
      (sum, transaction) => sum + transaction.amount,
    );
    return (total / daysElapsed) * daysInMonth;
  }

  String? _extractReference(String content) {
    final match = _referencePattern.firstMatch(content);
    return match?.group(1)?.trim();
  }

  String? _extractMerchant(String content) {
    for (final pattern in _merchantPatterns) {
      final match = pattern.firstMatch(content);
      final merchant = match?.group(1)?.trim();
      if (merchant == null || merchant.isEmpty) continue;
      final cleaned = merchant
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(
            RegExp(
              r'\b(a/c|account|rs|inr|debited)\b.*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (cleaned.length >= 2) return cleaned;
    }
    return null;
  }

  String _snippet(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 177)}...';
  }

  String _dateLabel(DateTime date) {
    return DateFormat('d MMM yyyy').format(date);
  }

  String _rangeLabel(SpendingDateRange range) {
    final singleDay = range.end.difference(range.start).inDays == 1;
    if (singleDay) return _dateLabel(range.start);
    final inclusiveEnd = range.end.subtract(const Duration(days: 1));
    return '${_dateLabel(range.start)} to ${_dateLabel(inclusiveEnd)}';
  }

  String _formatCurrency(double amount) {
    final decimals = amount == amount.roundToDouble() ? 0 : 2;
    return NumberFormat.currency(
      locale: 'en_IN',
      symbol: '\u20B9',
      decimalDigits: decimals,
    ).format(amount);
  }

  bool _hasSpendIntent(String query) {
    final normalized = _normalizeText(query);
    return RegExp(
      r'\b(spend|spent|expense|expenses|expenditure|paid|payment|kharcha|kharch)\b',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  String _normalizeText(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
