import 'package:intl/intl.dart';

import '../models/entity.dart';
import 'database_service.dart';

class LocalInsightResult {
  const LocalInsightResult({required this.answer, this.evidence = const []});

  final String answer;
  final List<Entity> evidence;
}

class LocalDeviceInsightService {
  LocalDeviceInsightService({
    DatabaseService? database,
    DateTime Function()? nowProvider,
  }) : _database = database ?? DatabaseService.instance,
       _nowProvider = nowProvider ?? DateTime.now;

  final DatabaseService _database;
  final DateTime Function() _nowProvider;

  Future<LocalInsightResult?> answerIfSupported(String query) async {
    final normalized = _normalize(query);
    if (_isOrderQuery(normalized)) {
      return _answerOrderQuery(normalized);
    }
    if (_isSpamQuery(normalized)) {
      return _answerSpamQuery(normalized);
    }
    return null;
  }

  bool _isOrderQuery(String query) {
    final asksOrders = RegExp(
      r'\b(order|orders|package|packages|packaging|parcel|shipment|delivery|deliveries)\b',
      caseSensitive: false,
    ).hasMatch(query);
    final hasWindow = RegExp(
      r'\b(last\s+48\s+hours|48\s+hours|last\s+2\s+days|two\s+days|recent|today|yesterday)\b',
      caseSensitive: false,
    ).hasMatch(query);
    return asksOrders && hasWindow;
  }

  bool _isSpamQuery(String query) {
    return RegExp(
          r'\b(spam|scam|fraud|unwanted|promotional|block)\b',
          caseSensitive: false,
        ).hasMatch(query) &&
        RegExp(
          r'\b(sms|message|messages|call|calls|number|numbers)\b',
          caseSensitive: false,
        ).hasMatch(query);
  }

  Future<LocalInsightResult> _answerOrderQuery(String query) async {
    final range = _orderRange(query);
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: const ['SMS', 'GMAIL', 'NOTIFICATION', 'CHAT'],
    );
    final orderItems =
        entities.map(_parseOrderEvidence).whereType<_OrderEvidence>().toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (orderItems.isEmpty) {
      return LocalInsightResult(
        answer:
            'I checked ${entities.length} synced local item${entities.length == 1 ? '' : 's'} from ${range.label}, but found no clear order, package, shipment, or delivery evidence. Connect Gmail notifications, SMS Messages, and shopping-app notifications, then ask again after new alerts arrive.',
      );
    }

    final buffer = StringBuffer()
      ..writeln(
        'I found ${orderItems.length} order/package update${orderItems.length == 1 ? '' : 's'} from ${range.label}.',
      )
      ..writeln()
      ..writeln('Latest updates:');
    for (final item in orderItems.take(8)) {
      final source = item.sourceLabel.isEmpty
          ? item.sourceConnector
          : item.sourceLabel;
      buffer.writeln(
        '- ${item.status}: ${source.isEmpty ? 'Unknown source' : source} (${_timeLabel(item.timestamp)})',
      );
    }

    return LocalInsightResult(
      answer: buffer.toString().trimRight(),
      evidence: orderItems.map((item) => item.entity).take(10).toList(),
    );
  }

  Future<LocalInsightResult> _answerSpamQuery(String query) async {
    final now = _nowProvider();
    final start = now.subtract(const Duration(days: 7));
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: start.millisecondsSinceEpoch,
      endAt: now.millisecondsSinceEpoch,
      sourceConnectors: const ['SMS', 'NOTIFICATION'],
    );
    final spamItems =
        entities.map(_parseSpamEvidence).whereType<_SpamEvidence>().toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final asksBlock = RegExp(r'\b(block|stop|remove|delete)\b').hasMatch(query);
    final asksCalls = RegExp(r'\b(call|calls)\b').hasMatch(query);
    final buffer = StringBuffer();
    if (spamItems.isEmpty) {
      buffer.write(
        'I checked synced SMS/notification data from the last 7 days and found no high-confidence spam messages. Call-log spam detection is not connected yet, so I cannot verify spam calls from local data.',
      );
    } else {
      buffer
        ..writeln(
          'I found ${spamItems.length} likely spam message${spamItems.length == 1 ? '' : 's'} in synced SMS/notification data from the last 7 days.',
        )
        ..writeln()
        ..writeln('Top signals:');
      for (final item in spamItems.take(5)) {
        buffer.writeln('- ${item.sender}: ${item.reason}');
      }
    }

    if (asksCalls) {
      buffer
        ..writeln()
        ..write(
          'Call-log spam detection is not connected yet, so I cannot verify spam calls from local data.',
        );
    }

    if (asksBlock) {
      buffer
        ..writeln()
        ..write(
          'I did not block or delete anything. Android requires PIE to be the default SMS app or have a separate call-screening/blocking role before it can block senders. Current production behavior is review-only.',
        );
    }

    return LocalInsightResult(
      answer: buffer.toString(),
      evidence: spamItems.map((item) => item.entity).take(10).toList(),
    );
  }

  _DateRange _orderRange(String query) {
    final now = _nowProvider();
    if (query.contains('today')) {
      final start = DateTime(now.year, now.month, now.day);
      return _DateRange(label: 'today', start: start, end: now);
    }
    if (query.contains('yesterday')) {
      final today = DateTime(now.year, now.month, now.day);
      final start = today.subtract(const Duration(days: 1));
      return _DateRange(label: 'yesterday', start: start, end: today);
    }
    final start = now.subtract(const Duration(hours: 48));
    return _DateRange(label: 'the last 48 hours', start: start, end: now);
  }

  _OrderEvidence? _parseOrderEvidence(Entity entity) {
    final content = entity.content?.trim() ?? '';
    if (content.isEmpty) return null;
    final lower = content.toLowerCase();
    if (!RegExp(
      r'\b(order|package|parcel|shipment|delivery|delivered|shipped|packed|arriving|out for delivery|tracking)\b',
    ).hasMatch(lower)) {
      return null;
    }
    if (RegExp(r'\botp|verification code|password\b').hasMatch(lower)) {
      return null;
    }

    return _OrderEvidence(
      entity: entity,
      status: _orderStatus(lower),
      sourceLabel: _sourceLabel(content),
      sourceConnector: entity.sourceConnector ?? '',
      timestamp: entity.createdAt,
    );
  }

  _SpamEvidence? _parseSpamEvidence(Entity entity) {
    final content = entity.content?.trim() ?? '';
    if (content.isEmpty) return null;
    final lower = content.toLowerCase();
    if (RegExp(
      r'\b(otp|one time password|transaction|debited|credited|delivered|order|appointment)\b',
    ).hasMatch(lower)) {
      return null;
    }

    var score = 0;
    final reasons = <String>[];
    void scoreIf(bool condition, int points, String reason) {
      if (!condition) return;
      score += points;
      reasons.add(reason);
    }

    scoreIf(
      RegExp(r'https?://|www\.|bit\.ly|tinyurl').hasMatch(lower),
      2,
      'contains a link',
    );
    scoreIf(
      RegExp(r'\b(win|winner|prize|lottery|reward)\b').hasMatch(lower),
      3,
      'prize/winner wording',
    );
    scoreIf(
      RegExp(
        r'\b(loan|credit card|pre-approved|insurance|casino|bet|crypto|investment)\b',
      ).hasMatch(lower),
      2,
      'promotional finance/gambling wording',
    );
    scoreIf(
      RegExp(
        r'\b(urgent|kyc|blocked|verify now|limited time|click)\b',
      ).hasMatch(lower),
      2,
      'urgent click/verification wording',
    );
    scoreIf(
      RegExp(r'\b(unsubscribe|stop to opt out|optout)\b').hasMatch(lower),
      1,
      'bulk-message wording',
    );

    if (score < 3) return null;

    return _SpamEvidence(
      entity: entity,
      sender: _senderLabel(content),
      reason: reasons.take(3).join(', '),
      score: score,
    );
  }

  String _orderStatus(String lower) {
    if (lower.contains('out for delivery')) return 'Out for delivery';
    if (lower.contains('delivered')) return 'Delivered';
    if (lower.contains('shipped') || lower.contains('dispatch')) {
      return 'Shipped';
    }
    if (lower.contains('packed') || lower.contains('packaging')) {
      return 'Packed';
    }
    if (lower.contains('arriving') || lower.contains('arrival')) {
      return 'Arriving';
    }
    if (lower.contains('cancel')) return 'Cancelled';
    return 'Order update';
  }

  String _sourceLabel(String content) {
    final notification = RegExp(
      r'^Notification from ([^:]+):',
      caseSensitive: false,
    ).firstMatch(content);
    if (notification != null) return notification.group(1)?.trim() ?? '';

    final sms = RegExp(
      r'From/To:\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(content);
    if (sms != null) return sms.group(1)?.trim() ?? '';
    return '';
  }

  String _senderLabel(String content) {
    final label = _sourceLabel(content);
    return label.isEmpty ? 'Unknown sender' : label;
  }

  String _timeLabel(int timestamp) {
    return DateFormat(
      'd MMM, h:mm a',
    ).format(DateTime.fromMillisecondsSinceEpoch(timestamp));
  }

  String _normalize(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}

class _DateRange {
  const _DateRange({
    required this.label,
    required this.start,
    required this.end,
  });

  final String label;
  final DateTime start;
  final DateTime end;
}

class _OrderEvidence {
  const _OrderEvidence({
    required this.entity,
    required this.status,
    required this.sourceLabel,
    required this.sourceConnector,
    required this.timestamp,
  });

  final Entity entity;
  final String status;
  final String sourceLabel;
  final String sourceConnector;
  final int timestamp;
}

class _SpamEvidence {
  const _SpamEvidence({
    required this.entity,
    required this.sender,
    required this.reason,
    required this.score,
  });

  final Entity entity;
  final String sender;
  final String reason;
  final int score;
}
