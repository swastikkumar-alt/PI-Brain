import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/models/entity.dart';
import 'package:pie_mobile/services/local_device_insight_service.dart';
import 'package:pie_mobile/services/database_service.dart';

void main() {
  group('LocalDeviceInsightService', () {
    test('summarizes order and package updates from the last 48 hours', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'order_1',
            source: 'GMAIL',
            content:
                'Notification from Amazon: Your package is out for delivery.',
          ),
          _entity(
            id: 'order_2',
            source: 'SMS',
            content:
                'Received SMS\nFrom/To: FLPKRT\nDate: 1783528200000\n\nYour order has shipped. Tracking ID ABC.',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'do i got any orders or packaging in last 48 hours',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('2 order/package updates'));
      expect(result.answer, contains('Out for delivery'));
      expect(result.answer, contains('Shipped'));
      expect(result.evidence, hasLength(2));
    });

    test('reports no order evidence without hallucinating', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(id: 'normal_1', content: 'Notification from Gmail: Hello.'),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'any packages in last 48 hours',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('found no clear order'));
    });

    test('classifies commerce notification order states', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'amazon_shipped',
            source: 'ORDER',
            content:
                'Notification from Amazon: Your order has shipped and will arrive tomorrow.',
          ),
          _entity(
            id: 'flipkart_cancelled',
            source: 'ORDER',
            content:
                'Notification from Flipkart: Your order was cancelled. Refund will be processed.',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'did I get any Amazon orders in last 48 hours',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('Shipped'));
      expect(result.answer, contains('Cancelled'));
      expect(result.evidence, hasLength(2));
    });

    test('detects likely spam and refuses unsafe blocking', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'spam_1',
            source: 'SMS',
            content:
                'Received SMS\nFrom/To: AD-LOAN\nDate: 1783528200000\n\nCongratulations winner, pre-approved loan. Click http://x.test now.',
          ),
          _entity(
            id: 'otp_1',
            source: 'SMS',
            content: 'OTP is 123456 for payment of Rs 500.',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'did i get some spam calls and messages and can you block those messages from sms',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('1 likely spam message'));
      expect(result.answer, contains('I did not delete anything'));
      expect(result.evidence.single.id, 'spam_1');
    });

    test('counts received messages for a date range', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'sms_received',
            source: 'SMS',
            content: 'Received SMS\nFrom/To: MOM\nDate: 1783528200000\n\nHi',
          ),
          _entity(
            id: 'sms_sent',
            source: 'SMS',
            content: 'Sent SMS\nFrom/To: MOM\nDate: 1783528200000\n\nHi',
          ),
          _entity(
            id: 'wa_1',
            source: 'CHAT',
            content: 'Notification from WhatsApp: Rahul: Hello',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'how many messages did i received today',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('2 received messages'));
      expect(result.evidence, hasLength(2));
    });

    test('summarizes important Gmail notifications', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'gmail_important',
            source: 'GMAIL',
            content:
                'Notification from Gmail: Finance Team: Urgent invoice approval required today.',
          ),
          _entity(
            id: 'gmail_noise',
            source: 'GMAIL',
            content: 'Notification from Gmail: Newsletter update.',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'did i get some important emails today',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('1 potentially important email'));
      expect(result.evidence.single.id, 'gmail_important');
    });

    test('summarizes missed calls from call log evidence', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'call_missed',
            source: 'CALL_LOG',
            content:
                'Call Log\nType: Missed\nNumber: 9458420654\nDate: 1783528200000\nDuration seconds: 0',
            timestamp: DateTime(2026, 7, 8, 12).millisecondsSinceEpoch,
          ),
          _entity(
            id: 'call_incoming',
            source: 'CALL_LOG',
            content:
                'Call Log\nType: Incoming\nNumber: 111\nDate: 1783528200000\nDuration seconds: 25',
            timestamp: DateTime(2026, 7, 8, 13).millisecondsSinceEpoch,
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final result = await service.answerIfSupported(
        'did i get any calls from yesterday that i have not answered',
      );

      expect(result, isNotNull);
      expect(result!.answer, contains('1 missed/unanswered call'));
      expect(result.evidence.single.id, 'call_missed');
    });

    test('summarizes health steps and sleep evidence', () async {
      final service = LocalDeviceInsightService(
        database: _FakeDatabaseService([
          _entity(
            id: 'health_1',
            source: 'HEALTH',
            content:
                'Health Summary\nDate: 2026-07-09\nSteps: 8123\nSleep minutes: 420\nSleep start: 2026-07-08T23:10:00Z\nSleep end: 2026-07-09T06:10:00Z',
          ),
        ]),
        nowProvider: () => DateTime(2026, 7, 9, 16),
      );

      final steps = await service.answerIfSupported(
        'how much steps did i complete everyday',
      );
      final sleep = await service.answerIfSupported('when was i asleep');

      expect(steps, isNotNull);
      expect(steps!.answer, contains('8123'));
      expect(sleep, isNotNull);
      expect(sleep!.answer, contains('7 h'));
    });
  });
}

Entity _entity({
  required String id,
  required String content,
  String source = 'NOTIFICATION',
  int? timestamp,
}) {
  final createdAt =
      timestamp ?? DateTime(2026, 7, 9, 12).millisecondsSinceEpoch;
  return Entity(
    id: id,
    entityType: 'document',
    sourceConnector: source,
    content: content,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

class _FakeDatabaseService implements DatabaseService {
  _FakeDatabaseService(this.entities);

  final List<Entity> entities;

  @override
  Future<List<Entity>> getEntitiesCreatedBetween({
    required int startAt,
    required int endAt,
    List<String> sourceConnectors = const [],
  }) async {
    return entities.where((entity) {
      final sourceAllowed =
          sourceConnectors.isEmpty ||
          sourceConnectors.contains(entity.sourceConnector);
      return sourceAllowed &&
          entity.createdAt >= startAt &&
          entity.createdAt < endAt;
    }).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
