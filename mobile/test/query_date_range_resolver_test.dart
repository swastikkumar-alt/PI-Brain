import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/services/query_date_range_resolver.dart';

void main() {
  group('QueryDateRangeResolver', () {
    const resolver = QueryDateRangeResolver();
    final now = DateTime(2026, 7, 10, 16, 30);

    test('resolves relative day ranges', () {
      final yesterday = resolver.tryResolve(
        'what happened yesterday',
        now: now,
      );
      final today = resolver.tryResolve('what happened today', now: now);

      expect(yesterday!.start, DateTime(2026, 7, 9));
      expect(yesterday.end, DateTime(2026, 7, 10));
      expect(today!.start, DateTime(2026, 7, 10));
      expect(today.end, DateTime(2026, 7, 11));
    });

    test('resolves explicit dates', () {
      final range = resolver.tryResolve('show orders on 8 july', now: now);

      expect(range!.label, '8 Jul 2026');
      expect(range.start, DateTime(2026, 7, 8));
      expect(range.end, DateTime(2026, 7, 9));
    });

    test('resolves month-to-date', () {
      final range = resolver.tryResolve('spend this month till date', now: now);

      expect(range!.label, 'this month till date');
      expect(range.start, DateTime(2026, 7, 1));
      expect(range.end, DateTime(2026, 7, 11));
      expect(range.displayLabel, '1 Jul 2026 to 10 Jul 2026');
    });

    test('resolves rolling hours', () {
      final range = resolver.tryResolve('orders in last 48 hours', now: now);

      expect(range!.label, 'last 48 hours');
      expect(range.start, DateTime(2026, 7, 8, 16, 30));
      expect(range.end.isAfter(now), true);
    });
  });
}
