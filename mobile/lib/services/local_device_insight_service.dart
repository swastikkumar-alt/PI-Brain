import 'package:intl/intl.dart';

import '../models/entity.dart';
import 'database_service.dart';
import 'query_date_range_resolver.dart';

class LocalInsightResult {
  const LocalInsightResult({required this.answer, this.evidence = const []});

  final String answer;
  final List<Entity> evidence;
}

class LocalDeviceInsightService {
  LocalDeviceInsightService({
    DatabaseService? database,
    DateTime Function()? nowProvider,
    QueryDateRangeResolver? dateRangeResolver,
  }) : _database = database ?? DatabaseService.instance,
       _nowProvider = nowProvider ?? DateTime.now,
       _dateRangeResolver = dateRangeResolver ?? const QueryDateRangeResolver();

  final DatabaseService _database;
  final DateTime Function() _nowProvider;
  final QueryDateRangeResolver _dateRangeResolver;

  Future<LocalInsightResult?> answerIfSupported(String query) async {
    final normalized = _normalize(query);
    if (_isMessageCountQuery(normalized)) {
      return _answerMessageCountQuery(normalized);
    }
    if (_isEmailQuery(normalized)) {
      return _answerEmailQuery(normalized);
    }
    if (_isSpamQuery(normalized)) {
      return _answerSpamQuery(normalized);
    }
    if (_isCallQuery(normalized)) {
      return _answerCallQuery(normalized);
    }
    if (_isHealthQuery(normalized)) {
      return _answerHealthQuery(normalized);
    }
    if (_isOrderQuery(normalized)) {
      return _answerOrderQuery(normalized);
    }
    return null;
  }

  bool _isMessageCountQuery(String query) {
    return RegExp(
          r'\b(how many|count|number of)\b',
          caseSensitive: false,
        ).hasMatch(query) &&
        RegExp(
          r'\b(message|messages|sms|whatsapp|chat|chats)\b',
          caseSensitive: false,
        ).hasMatch(query);
  }

  bool _isEmailQuery(String query) {
    return RegExp(
          r'\b(email|emails|gmail|mail|mails)\b',
          caseSensitive: false,
        ).hasMatch(query) &&
        RegExp(
          r'\b(important|urgent|priority|received|got|summary|summarize|unread)\b',
          caseSensitive: false,
        ).hasMatch(query);
  }

  bool _isCallQuery(String query) {
    return RegExp(
      r'\b(call|calls|missed|unanswered|not answered|spam call)\b',
      caseSensitive: false,
    ).hasMatch(query);
  }

  bool _isHealthQuery(String query) {
    return RegExp(
      r'\b(step|steps|sleep|slept|asleep|wake|woke|health)\b',
      caseSensitive: false,
    ).hasMatch(query);
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
      sourceConnectors: const ['SMS', 'GMAIL', 'NOTIFICATION', 'CHAT', 'ORDER'],
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

  Future<LocalInsightResult> _answerMessageCountQuery(String query) async {
    final range = _resolveRange(query, fallback: _todayRange());
    final sources = query.contains('whatsapp') || query.contains('chat')
        ? const ['CHAT', 'NOTIFICATION']
        : const ['SMS', 'CHAT', 'NOTIFICATION'];
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: sources,
    );
    final received = entities.where(_isReceivedMessageEvidence).toList();
    final bySource = <String, int>{};
    for (final entity in received) {
      final source = entity.sourceConnector ?? 'unknown';
      bySource[source] = (bySource[source] ?? 0) + 1;
    }

    if (received.isEmpty) {
      return LocalInsightResult(
        answer:
            'I checked ${entities.length} synced local item${entities.length == 1 ? '' : 's'} for ${range.label}, but found no received message evidence. Turn on SMS Messages, WhatsApp Notifications, or Live Notifications and sync again.',
      );
    }

    final parts = bySource.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
    return LocalInsightResult(
      answer:
          'For ${range.label}, I found ${received.length} received message${received.length == 1 ? '' : 's'} in synced local data. Source breakdown: $parts.',
      evidence: received.take(10).toList(),
    );
  }

  Future<LocalInsightResult> _answerEmailQuery(String query) async {
    final range = _resolveRange(
      query,
      fallback: _DateRange(
        label: 'the last 7 days',
        start: _nowProvider().subtract(const Duration(days: 7)),
        end: _nowProvider(),
      ),
    );
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: const ['GMAIL'],
    );
    final important =
        entities.map(_parseEmailEvidence).whereType<_EmailEvidence>().toList()
          ..sort((a, b) {
            final score = b.score.compareTo(a.score);
            return score != 0 ? score : b.timestamp.compareTo(a.timestamp);
          });

    if (important.isEmpty) {
      return LocalInsightResult(
        answer:
            'I checked ${entities.length} synced Gmail notification item${entities.length == 1 ? '' : 's'} from ${range.label}, but found no high-confidence important email evidence. For full mailbox answers, connect Gmail API OAuth; notification access only sees delivered notification summaries.',
      );
    }

    final buffer = StringBuffer()
      ..writeln(
        'I found ${important.length} potentially important email${important.length == 1 ? '' : 's'} from ${range.label}.',
      )
      ..writeln()
      ..writeln('Top emails:');
    for (final item in important.take(6)) {
      buffer.writeln('- ${item.sender}: ${item.reason}');
    }

    return LocalInsightResult(
      answer: buffer.toString().trimRight(),
      evidence: important.map((item) => item.entity).take(10).toList(),
    );
  }

  Future<LocalInsightResult> _answerCallQuery(String query) async {
    final range = _resolveRange(query, fallback: _todayRange());
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: const ['CALL_LOG'],
    );
    final calls =
        entities.map(_parseCallEvidence).whereType<_CallEvidence>().toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final wantsMissed = RegExp(
      r'\b(missed|unanswered|not answered|not answer)\b',
    ).hasMatch(query);
    final visible = wantsMissed
        ? calls.where((call) => call.type == 'Missed').toList()
        : calls;

    if (visible.isEmpty) {
      final qualifier = wantsMissed ? 'missed/unanswered ' : '';
      return LocalInsightResult(
        answer:
            'I checked ${entities.length} synced call-log item${entities.length == 1 ? '' : 's'} for ${range.label}, but found no ${qualifier}call evidence. Turn on Call Logs in Settings and import calls again if this looks wrong.',
      );
    }

    final missed = calls.where((call) => call.type == 'Missed').length;
    final incoming = calls.where((call) => call.type == 'Incoming').length;
    final outgoing = calls.where((call) => call.type == 'Outgoing').length;
    final buffer = StringBuffer()
      ..writeln(
        'For ${range.label}, I found ${visible.length} ${wantsMissed ? 'missed/unanswered ' : ''}call${visible.length == 1 ? '' : 's'} in synced call logs.',
      )
      ..writeln(
        'Breakdown: missed $missed, incoming $incoming, outgoing $outgoing.',
      )
      ..writeln()
      ..writeln('Latest calls:');
    for (final call in visible.take(6)) {
      buffer.writeln(
        '- ${call.type}: ${call.label} (${_timeLabel(call.timestamp)})',
      );
    }

    return LocalInsightResult(
      answer: buffer.toString().trimRight(),
      evidence: visible.map((call) => call.entity).take(10).toList(),
    );
  }

  Future<LocalInsightResult> _answerHealthQuery(String query) async {
    final range = _resolveRange(
      query,
      fallback: _DateRange(
        label: 'the last 7 days',
        start: DateTime(
          _nowProvider().year,
          _nowProvider().month,
          _nowProvider().day,
        ).subtract(const Duration(days: 6)),
        end: DateTime(
          _nowProvider().year,
          _nowProvider().month,
          _nowProvider().day,
        ).add(const Duration(days: 1)),
      ),
    );
    final entities = await _database.getEntitiesCreatedBetween(
      startAt: range.start.millisecondsSinceEpoch,
      endAt: range.end.millisecondsSinceEpoch,
      sourceConnectors: const ['HEALTH'],
    );
    final days =
        entities.map(_parseHealthEvidence).whereType<_HealthEvidence>().toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (days.isEmpty) {
      return LocalInsightResult(
        answer:
            'I checked ${entities.length} synced Health Connect item${entities.length == 1 ? '' : 's'} for ${range.label}, but found no steps or sleep summary. Turn on Health Connect in Settings, grant Steps and Sleep reads, then import health data.',
      );
    }

    if (query.contains('sleep') ||
        query.contains('asleep') ||
        query.contains('slept')) {
      return _buildSleepAnswer(range, days);
    }

    final totalSteps = days.fold<int>(0, (sum, day) => sum + day.steps);
    final avgSteps = (totalSteps / days.length).round();
    final buffer = StringBuffer()
      ..writeln(
        'For ${range.label}, I found ${days.length} Health Connect day${days.length == 1 ? '' : 's'}.',
      )
      ..writeln('Total steps: $totalSteps. Daily average: $avgSteps.')
      ..writeln()
      ..writeln('Daily steps:');
    for (final day in days) {
      buffer.writeln('- ${day.dateLabel}: ${day.steps}');
    }

    return LocalInsightResult(
      answer: buffer.toString().trimRight(),
      evidence: days.map((day) => day.entity).take(10).toList(),
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
          'For spam calls, import Call Logs first so PIE can review missed/blocked/rejected call evidence. Actual call blocking still requires an Android-supported phone/call-screening role.',
        );
    }

    if (asksBlock) {
      buffer
        ..writeln()
        ..write(
          'I did not delete anything from the phone in chat. I can review and mark spam locally now. Real SMS deletion is enabled only after PIE has the required Android SMS/default-handler capability; otherwise the safe action is to show candidates for your approval.',
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

  _DateRange _todayRange() {
    final now = _nowProvider();
    final start = DateTime(now.year, now.month, now.day);
    return _DateRange(
      label: 'today',
      start: start,
      end: start.add(const Duration(days: 1)),
    );
  }

  _DateRange _resolveRange(String query, {required _DateRange fallback}) {
    final resolved = _dateRangeResolver.tryResolve(query, now: _nowProvider());
    if (resolved == null) return fallback;
    return _DateRange(
      label: resolved.displayLabel,
      start: resolved.start,
      end: resolved.end,
    );
  }

  bool _isReceivedMessageEvidence(Entity entity) {
    final content = entity.content?.toLowerCase() ?? '';
    final source = entity.sourceConnector ?? '';
    if (source == 'SMS') return content.startsWith('received sms');
    if (source == 'CHAT') return true;
    if (source == 'NOTIFICATION') {
      return content.contains('notification from') &&
          !content.contains('pie notification sync');
    }
    return false;
  }

  _OrderEvidence? _parseOrderEvidence(Entity entity) {
    final content = entity.content?.trim() ?? '';
    if (content.isEmpty) return null;
    final lower = content.toLowerCase();
    if (!RegExp(
      r'\b(order|package|parcel|shipment|delivery|delivered|shipped|packed|arriving|out for delivery|tracking|dispatched|cancelled|canceled|return|refund)\b',
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

  _EmailEvidence? _parseEmailEvidence(Entity entity) {
    final content = entity.content?.trim() ?? '';
    if (content.isEmpty) return null;
    final lower = content.toLowerCase();
    var score = 0;
    final reasons = <String>[];
    void addIf(bool condition, int points, String reason) {
      if (!condition) return;
      score += points;
      reasons.add(reason);
    }

    addIf(
      RegExp(
        r'\b(urgent|important|action required|deadline)\b',
      ).hasMatch(lower),
      3,
      'urgent/action wording',
    );
    addIf(
      RegExp(
        r'\b(invoice|payment|receipt|order|delivery|ticket|booking)\b',
      ).hasMatch(lower),
      2,
      'transaction/workflow signal',
    );
    addIf(
      RegExp(
        r'\b(interview|meeting|schedule|document|contract|approval)\b',
      ).hasMatch(lower),
      2,
      'work or approval signal',
    );
    addIf(
      RegExp(r'\b(security alert|sign-in|login|password)\b').hasMatch(lower),
      3,
      'security signal',
    );
    if (score < 2) return null;

    return _EmailEvidence(
      entity: entity,
      sender: _sourceLabel(content).isEmpty ? 'Gmail' : _sourceLabel(content),
      reason: reasons.take(3).join(', '),
      score: score,
      timestamp: entity.createdAt,
    );
  }

  _CallEvidence? _parseCallEvidence(Entity entity) {
    final content = entity.content ?? '';
    if (content.trim().isEmpty) return null;
    final type =
        RegExp(
          r'^Type:\s*([^\n]+)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(content)?.group(1)?.trim() ??
        'Unknown';
    final number =
        RegExp(
          r'^Number:\s*([^\n]+)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(content)?.group(1)?.trim() ??
        'Unknown';
    final name = RegExp(
      r'^Name:\s*([^\n]+)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(content)?.group(1)?.trim();
    return _CallEvidence(
      entity: entity,
      type: type,
      label: (name == null || name.isEmpty) ? number : '$name ($number)',
      timestamp: entity.createdAt,
    );
  }

  _HealthEvidence? _parseHealthEvidence(Entity entity) {
    final content = entity.content ?? '';
    if (content.trim().isEmpty) return null;
    final date =
        RegExp(
          r'^Date:\s*([^\n]+)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(content)?.group(1)?.trim() ??
        _dateLabel(DateTime.fromMillisecondsSinceEpoch(entity.createdAt));
    final steps =
        int.tryParse(
          RegExp(
                r'^Steps:\s*(\d+)',
                multiLine: true,
                caseSensitive: false,
              ).firstMatch(content)?.group(1) ??
              '0',
        ) ??
        0;
    final sleepMinutes =
        int.tryParse(
          RegExp(
                r'^Sleep minutes:\s*(\d+)',
                multiLine: true,
                caseSensitive: false,
              ).firstMatch(content)?.group(1) ??
              '0',
        ) ??
        0;
    final sleepStart = RegExp(
      r'^Sleep start:\s*([^\n]*)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(content)?.group(1)?.trim();
    final sleepEnd = RegExp(
      r'^Sleep end:\s*([^\n]*)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(content)?.group(1)?.trim();
    return _HealthEvidence(
      entity: entity,
      dateLabel: date,
      steps: steps,
      sleepMinutes: sleepMinutes,
      sleepStart: sleepStart ?? '',
      sleepEnd: sleepEnd ?? '',
      timestamp: entity.createdAt,
    );
  }

  LocalInsightResult _buildSleepAnswer(
    _DateRange range,
    List<_HealthEvidence> days,
  ) {
    final sleepDays = days.where((day) => day.sleepMinutes > 0).toList();
    if (sleepDays.isEmpty) {
      return LocalInsightResult(
        answer:
            'I found Health Connect rows for ${range.label}, but none had sleep minutes. Grant Sleep read access and import again.',
        evidence: days.map((day) => day.entity).take(10).toList(),
      );
    }

    final total = sleepDays.fold<int>(0, (sum, day) => sum + day.sleepMinutes);
    final avg = (total / sleepDays.length).round();
    final buffer = StringBuffer()
      ..writeln(
        'For ${range.label}, I found ${sleepDays.length} sleep day${sleepDays.length == 1 ? '' : 's'} from Health Connect.',
      )
      ..writeln('Average sleep: ${_minutesLabel(avg)}.')
      ..writeln()
      ..writeln('Sleep windows:');
    for (final day in sleepDays) {
      final window = day.sleepStart.isEmpty && day.sleepEnd.isEmpty
          ? ''
          : ' (${day.sleepStart} to ${day.sleepEnd})';
      buffer.writeln(
        '- ${day.dateLabel}: ${_minutesLabel(day.sleepMinutes)}$window',
      );
    }

    if (sleepDays.length >= 6) {
      final recent = sleepDays.skip(sleepDays.length - 3).toList();
      final previous = sleepDays.skip(sleepDays.length - 6).take(3).toList();
      final recentAvg =
          recent.fold<int>(0, (sum, day) => sum + day.sleepMinutes) /
          recent.length;
      final previousAvg =
          previous.fold<int>(0, (sum, day) => sum + day.sleepMinutes) /
          previous.length;
      final diff = (recentAvg - previousAvg).round();
      buffer
        ..writeln()
        ..write(
          diff >= 0
              ? 'Recent sleep is about ${_minutesLabel(diff)} higher than the previous comparable days.'
              : 'Recent sleep is about ${_minutesLabel(diff.abs())} lower than the previous comparable days.',
        );
    }

    return LocalInsightResult(
      answer: buffer.toString().trimRight(),
      evidence: sleepDays.map((day) => day.entity).take(10).toList(),
    );
  }

  String _orderStatus(String lower) {
    if (lower.contains('out for delivery')) return 'Out for delivery';
    if (lower.contains('delivered')) return 'Delivered';
    if (lower.contains('cancel')) return 'Cancelled';
    if (lower.contains('return')) return 'Return update';
    if (lower.contains('refund')) return 'Refund update';
    if (lower.contains('shipped') || lower.contains('dispatch')) {
      return 'Shipped';
    }
    if (lower.contains('packed') || lower.contains('packaging')) {
      return 'Packed';
    }
    if (lower.contains('arriving') || lower.contains('arrival')) {
      return 'Arriving';
    }
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

  String _dateLabel(DateTime date) {
    return DateFormat('d MMM yyyy').format(date);
  }

  String _minutesLabel(int minutes) {
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    if (hours == 0) return '$rem min';
    if (rem == 0) return '$hours h';
    return '$hours h $rem min';
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

class _EmailEvidence {
  const _EmailEvidence({
    required this.entity,
    required this.sender,
    required this.reason,
    required this.score,
    required this.timestamp,
  });

  final Entity entity;
  final String sender;
  final String reason;
  final int score;
  final int timestamp;
}

class _CallEvidence {
  const _CallEvidence({
    required this.entity,
    required this.type,
    required this.label,
    required this.timestamp,
  });

  final Entity entity;
  final String type;
  final String label;
  final int timestamp;
}

class _HealthEvidence {
  const _HealthEvidence({
    required this.entity,
    required this.dateLabel,
    required this.steps,
    required this.sleepMinutes,
    required this.sleepStart,
    required this.sleepEnd,
    required this.timestamp,
  });

  final Entity entity;
  final String dateLabel;
  final int steps;
  final int sleepMinutes;
  final String sleepStart;
  final String sleepEnd;
  final int timestamp;
}
