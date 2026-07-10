import 'package:intl/intl.dart';

import '../models/entity.dart';
import 'database_service.dart';

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
    required this.currencySymbol,
    required this.sourceConnector,
    required this.evidence,
    required this.timestamp,
    this.merchant,
    this.reference,
  });

  final String entityId;
  final double amount;
  final String currencySymbol;
  final String sourceConnector;
  final String evidence;
  final int timestamp;
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

class SpendingInsightService {
  SpendingInsightService({
    DatabaseService? database,
    DateTime Function()? nowProvider,
  }) : _database = database ?? DatabaseService.instance,
       _nowProvider = nowProvider ?? DateTime.now;

  final DatabaseService _database;
  final DateTime Function() _nowProvider;

  static final _amountPattern = RegExp(
    r'(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.\d{1,2})?)|([0-9][0-9,]*(?:\.\d{1,2})?)\s*(?:rs\.?|inr)',
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

  bool canHandle(String query) {
    final normalized = _normalizeText(query);
    final asksAboutSpend = RegExp(
      r'\b(spend|spent|expense|expenses|expenditure|paid|payment|kharcha|kharch)\b',
      caseSensitive: false,
    ).hasMatch(normalized);
    final hasTimeRange = RegExp(
      r'\b(yesterday|yesteerday|yesterda|yesterd|kal|last day|previous day|today)\b',
      caseSensitive: false,
    ).hasMatch(normalized);

    return asksAboutSpend && hasTimeRange;
  }

  Future<SpendingInsightResult?> answerIfSupported(String query) async {
    if (!canHandle(query)) return null;

    final range = resolveRange(query, now: _nowProvider());
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: const ['SMS', 'GMAIL', 'NOTIFICATION', 'PAYMENT'],
    );

    return buildResult(query: query, range: range, entities: entities);
  }

  SpendingDateRange resolveRange(String query, {DateTime? now}) {
    final base = now ?? _nowProvider();
    final lower = _normalizeText(query);
    final today = DateTime(base.year, base.month, base.day);

    if (RegExp(
      r'\b(yesterday|yesteerday|yesterda|yesterd|kal|last day|previous day)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      final start = today.subtract(const Duration(days: 1));
      return SpendingDateRange(label: 'yesterday', start: start, end: today);
    }

    return SpendingDateRange(
      label: 'today',
      start: today,
      end: today.add(const Duration(days: 1)),
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
    final content = entity.content?.trim() ?? '';
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

      final start = (match.start - 90).clamp(0, content.length);
      final end = (match.end + 90).clamp(0, content.length);
      final window = content.substring(start, end);
      final windowLower = window.toLowerCase();

      if (_failedPattern.hasMatch(windowLower)) continue;
      if (_creditPattern.hasMatch(windowLower) &&
          !_debitPattern.hasMatch(windowLower)) {
        continue;
      }
      if (!_debitPattern.hasMatch(windowLower) &&
          !_debitPattern.hasMatch(lower)) {
        continue;
      }

      return SpendingTransaction(
        entityId: entity.id,
        amount: amount,
        currencySymbol: '₹',
        sourceConnector: entity.sourceConnector ?? 'unknown',
        evidence: _snippet(content),
        timestamp: entity.createdAt,
        merchant: _extractMerchant(content),
        reference: _extractReference(content),
      );
    }

    return null;
  }

  List<SpendingTransaction> _dedupeTransactions(
    List<SpendingTransaction> transactions,
  ) {
    final byKey = <String, SpendingTransaction>{};
    for (final transaction in transactions) {
      final key = _dedupeKey(transaction);
      final existing = byKey[key];
      if (existing == null ||
          transaction.evidence.length > existing.evidence.length) {
        byKey[key] = transaction;
      }
    }
    return byKey.values.toList();
  }

  String _dedupeKey(SpendingTransaction transaction) {
    final reference = transaction.reference;
    if (reference != null && reference.isNotEmpty) {
      return 'ref:${reference.toLowerCase()}';
    }

    final merchant = (transaction.merchant ?? 'unknown')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    final tenMinuteBucket =
        transaction.timestamp ~/ const Duration(minutes: 10).inMilliseconds;
    return [
      transaction.amount.toStringAsFixed(2),
      merchant,
      tenMinuteBucket,
    ].join('|');
  }

  String _buildSpendAnswer(
    SpendingDateRange range,
    List<SpendingTransaction> transactions,
  ) {
    final total = transactions.fold<double>(
      0,
      (sum, transaction) => sum + transaction.amount,
    );
    final dateLabel = _dateLabel(range.start);
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

    buffer
      ..writeln()
      ..write(
        'I counted only debit/payment evidence and excluded credits, refunds, cashback, OTP, pending, and failed transaction messages.',
      );

    return buffer.toString();
  }

  String _buildNoDataAnswer(SpendingDateRange range, List<Entity> entities) {
    final dateLabel = _dateLabel(range.start);
    if (entities.isEmpty) {
      return 'I could not calculate spend for $dateLabel because no SMS, Gmail, or payment notification data is synced locally for that date. Turn on SMS Messages and payment/bank notifications in Choose what PIE can read, run SMS import, then ask again.';
    }

    return 'I checked ${entities.length} synced local item${entities.length == 1 ? '' : 's'} for $dateLabel, but found no debit/payment transaction evidence. I did not count credits, refunds, cashback, OTP, pending, or failed transaction messages.';
  }

  double? _parseAmount(String? value) {
    if (value == null) return null;
    return double.tryParse(value.replaceAll(',', '').trim());
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

  String _formatCurrency(double amount) {
    final decimals = amount == amount.roundToDouble() ? 0 : 2;
    return NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: decimals,
    ).format(amount);
  }

  String _normalizeText(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
