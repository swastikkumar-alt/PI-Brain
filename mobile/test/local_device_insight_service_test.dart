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
      expect(result.answer, contains('I did not block or delete anything'));
      expect(
        result.answer,
        contains('Call-log spam detection is not connected'),
      );
      expect(result.evidence.single.id, 'spam_1');
    });
  });
}

Entity _entity({
  required String id,
  required String content,
  String source = 'NOTIFICATION',
}) {
  return Entity(
    id: id,
    entityType: 'document',
    sourceConnector: source,
    content: content,
    createdAt: DateTime(2026, 7, 9, 12).millisecondsSinceEpoch,
    updatedAt: DateTime(2026, 7, 9, 12).millisecondsSinceEpoch,
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
