import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/models/entity.dart';
import 'package:pie_mobile/services/spending_insight_service.dart';

void main() {
  group('SpendingInsightService', () {
    late SpendingInsightService service;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 7, 9, 16, 30);
      service = SpendingInsightService(nowProvider: () => now);
    });

    test('handles yesterday spending questions', () {
      expect(
        service.canHandle('how much did I spent yesterday on my app'),
        true,
      );
      expect(service.canHandle('how much did I spend yesteerday'), true);
      expect(service.canHandle('what is my expense kal'), true);
      expect(service.canHandle('how much did I spend on 8 july'), true);
      expect(
        service.canHandle('how much did I spent this month till date'),
        true,
      );
      expect(service.canHandle('message rahul that hi'), false);
    });

    test('resolves yesterday to a local calendar-day range', () {
      final range = service.resolveRange(
        'how much did I spend yesterday',
        now: now,
      );

      expect(range.label, 'yesterday');
      expect(range.start, DateTime(2026, 7, 8));
      expect(range.end, DateTime(2026, 7, 9));
    });

    test('resolves explicit day-month spending questions', () {
      final range = service.resolveRange(
        'how much did I spend on 8 july',
        now: DateTime(2026, 7, 10, 16, 30),
      );

      expect(range.label, '8 Jul 2026');
      expect(range.start, DateTime(2026, 7, 8));
      expect(range.end, DateTime(2026, 7, 9));
    });

    test('resolves today spending questions', () {
      final range = service.resolveRange(
        'how many did i spend today',
        now: DateTime(2026, 7, 10, 16, 30),
      );

      expect(range.label, 'today');
      expect(range.start, DateTime(2026, 7, 10));
      expect(range.end, DateTime(2026, 7, 11));
    });

    test('resolves this month till date spending questions', () {
      final range = service.resolveRange(
        'how much did i spent this month till date',
        now: DateTime(2026, 7, 10, 16, 30),
      );

      expect(range.label, 'this month till date');
      expect(range.start, DateTime(2026, 7, 1));
      expect(range.end, DateTime(2026, 7, 11));
    });

    test('totals debit and payment evidence for the requested day', () {
      final range = service.resolveRange('spend yesterday', now: now);
      final result = service.buildResult(
        query: 'how much did I spend yesterday',
        range: range,
        entities: [
          _entity(
            id: 'sms_1',
            content:
                'Received SMS\nFrom/To: HDFCBK\nDate: 1783528200000\n\n'
                'A/c XX123 debited by Rs. 120.50 at SWIGGY. UPI Ref 123456789012.',
          ),
          _entity(
            id: 'sms_2',
            content:
                'Received SMS\nFrom/To: GPAY\nDate: 1783530000000\n\n'
                'You paid INR 249 to ZOMATO on UPI. Txn ID ABCD987654.',
          ),
        ],
      );

      expect(result.transactions, hasLength(2));
      expect(result.answer, contains('**Total spent: ₹369.50**'));
      expect(result.answer, contains('8 Jul 2026'));
    });

    test('parses real rupee symbol payment evidence', () {
      final range = service.resolveRange('spend today', now: now);
      final result = service.buildResult(
        query: 'how much did I spend today',
        range: range,
        entities: [
          _entity(
            id: 'notif_rupee',
            source: 'PAYMENT',
            content:
                'Notification from GPay: Paid ₹150 to CAFE. UPI Ref 888888888888.',
          ),
        ],
      );

      expect(result.transactions, hasLength(1));
      expect(result.transactions.single.amount, 150);
      expect(result.answer, contains('**Total spent: ₹150**'));
    });

    test('totals month-to-date transactions with explicit range label', () {
      final range = service.resolveRange(
        'how much did I spent this month till date',
        now: DateTime(2026, 7, 10, 16, 30),
      );
      final result = service.buildResult(
        query: 'how much did I spent this month till date',
        range: range,
        entities: [
          _entity(
            id: 'month_1',
            content: 'A/c debited by Rs 100 at METRO. UPI Ref 111111111111.',
            timestamp: DateTime(2026, 7, 1, 12).millisecondsSinceEpoch,
          ),
          _entity(
            id: 'month_2',
            content: 'You paid INR 250 to PHARMACY. Txn ID XYZ987654321.',
            timestamp: DateTime(2026, 7, 10, 9).millisecondsSinceEpoch,
          ),
        ],
      );

      expect(result.transactions, hasLength(2));
      expect(result.answer, contains('For 1 Jul 2026 to 10 Jul 2026'));
      expect(result.answer, contains('**Total spent: ₹350**'));
    });

    test('excludes credits refunds otp and failed transactions', () {
      final range = service.resolveRange('spend yesterday', now: now);
      final result = service.buildResult(
        query: 'how much did I spend yesterday',
        range: range,
        entities: [
          _entity(
            id: 'credit',
            content: 'A/c XX123 credited by Rs 500 from refund.',
          ),
          _entity(id: 'otp', content: 'OTP is 123456 for payment of Rs 999.'),
          _entity(
            id: 'failed',
            content: 'Payment of Rs 399 failed at merchant.',
          ),
        ],
      );

      expect(result.transactions, isEmpty);
      expect(
        result.answer,
        contains('found no debit/payment transaction evidence'),
      );
    });

    test('deduplicates same transaction by reference id', () {
      final range = service.resolveRange('spend yesterday', now: now);
      final result = service.buildResult(
        query: 'how much did I spend yesterday',
        range: range,
        entities: [
          _entity(
            id: 'sms_1',
            content: 'A/c debited by Rs 150 at CAFE. UPI Ref 777777777777.',
          ),
          _entity(
            id: 'notif_1',
            source: 'PAYMENT',
            content: 'Paid ₹150 to CAFE. UPI Ref 777777777777.',
          ),
        ],
      );

      expect(result.transactions, hasLength(1));
      expect(result.answer, contains('**Total spent: ₹150**'));
    });

    test('reports missing synced transaction data clearly', () {
      final range = service.resolveRange('spend yesterday', now: now);
      final result = service.buildResult(
        query: 'how much did I spend yesterday',
        range: range,
        entities: const [],
      );

      expect(result.transactions, isEmpty);
      expect(
        result.answer,
        contains('no SMS, Gmail, or payment notification data'),
      );
      expect(result.answer, contains('8 Jul 2026'));
    });
  });
}

Entity _entity({
  required String id,
  required String content,
  String source = 'SMS',
  int? timestamp,
}) {
  final entityTimestamp =
      timestamp ?? DateTime(2026, 7, 8, 12).millisecondsSinceEpoch;
  return Entity(
    id: id,
    entityType: 'message',
    sourceConnector: source,
    content: content,
    createdAt: entityTimestamp,
    updatedAt: entityTimestamp,
  );
}
