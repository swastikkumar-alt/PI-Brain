import 'package:intl/intl.dart';

class QueryDateRange {
  const QueryDateRange({
    required this.label,
    required this.start,
    required this.end,
  });

  final String label;
  final DateTime start;
  final DateTime end;

  String get displayLabel {
    if (end.difference(start).inDays == 1) {
      return DateFormat('d MMM yyyy').format(start);
    }
    final inclusiveEnd = end.subtract(const Duration(days: 1));
    return '${DateFormat('d MMM yyyy').format(start)} to ${DateFormat('d MMM yyyy').format(inclusiveEnd)}';
  }
}

class QueryDateRangeResolver {
  const QueryDateRangeResolver();

  static const _monthNames = <String, int>{
    'jan': 1,
    'january': 1,
    'feb': 2,
    'february': 2,
    'mar': 3,
    'march': 3,
    'apr': 4,
    'april': 4,
    'may': 5,
    'jun': 6,
    'june': 6,
    'jul': 7,
    'july': 7,
    'aug': 8,
    'august': 8,
    'sep': 9,
    'sept': 9,
    'september': 9,
    'oct': 10,
    'october': 10,
    'nov': 11,
    'november': 11,
    'dec': 12,
    'december': 12,
  };

  QueryDateRange? tryResolve(String query, {DateTime? now}) {
    final base = now ?? DateTime.now();
    final lower = _normalize(query);
    final today = DateTime(base.year, base.month, base.day);

    final lastHours = RegExp(
      r'\blast\s+(\d{1,3})\s*(hour|hours|hr|hrs)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (lastHours != null) {
      final hours = int.tryParse(lastHours.group(1) ?? '');
      if (hours != null && hours > 0) {
        return QueryDateRange(
          label: 'last $hours hours',
          start: base.subtract(Duration(hours: hours)),
          end: base.add(const Duration(milliseconds: 1)),
        );
      }
    }

    final lastDays = RegExp(
      r'\blast\s+(\d{1,3})\s*(day|days)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (lastDays != null) {
      final days = int.tryParse(lastDays.group(1) ?? '');
      if (days != null && days > 0) {
        return QueryDateRange(
          label: 'last $days days',
          start: today.subtract(Duration(days: days - 1)),
          end: today.add(const Duration(days: 1)),
        );
      }
    }

    if (RegExp(
      r'\b(this month|current month|month to date|month-to-date|mtd|till date|to date|month till date)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return QueryDateRange(
        label: 'this month till date',
        start: DateTime(today.year, today.month),
        end: today.add(const Duration(days: 1)),
      );
    }

    if (RegExp(
      r'\b(yesterday|yesteerday|yesterda|yesterd|kal|last day|previous day)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      final start = today.subtract(const Duration(days: 1));
      return QueryDateRange(label: 'yesterday', start: start, end: today);
    }

    if (RegExp(r'\b(today|aaj)\b', caseSensitive: false).hasMatch(lower)) {
      return QueryDateRange(
        label: 'today',
        start: today,
        end: today.add(const Duration(days: 1)),
      );
    }

    final explicitDate = _parseExplicitDate(lower, today);
    if (explicitDate != null) {
      return QueryDateRange(
        label: DateFormat('d MMM yyyy').format(explicitDate),
        start: explicitDate,
        end: explicitDate.add(const Duration(days: 1)),
      );
    }

    return null;
  }

  DateTime? _parseExplicitDate(String lower, DateTime today) {
    final dayMonth = RegExp(
      r'\b(?:on\s+)?([0-3]?\d)(?:st|nd|rd|th)?[\s/-]+([a-z]{3,9}|\d{1,2})(?:[\s,/-]+(\d{2,4}))?\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (dayMonth != null) {
      final day = int.tryParse(dayMonth.group(1) ?? '');
      final month = _parseMonth(dayMonth.group(2));
      final year = _parseYear(dayMonth.group(3), today);
      return _validPastDate(day: day, month: month, year: year, today: today);
    }

    final monthDay = RegExp(
      r'\b(?:on\s+)?([a-z]{3,9})[\s/-]+([0-3]?\d)(?:st|nd|rd|th)?(?:[\s,/-]+(\d{2,4}))?\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (monthDay != null) {
      final month = _parseMonth(monthDay.group(1));
      final day = int.tryParse(monthDay.group(2) ?? '');
      final year = _parseYear(monthDay.group(3), today);
      return _validPastDate(day: day, month: month, year: year, today: today);
    }

    return null;
  }

  int? _parseMonth(String? value) {
    if (value == null || value.isEmpty) return null;
    final numeric = int.tryParse(value);
    if (numeric != null) return numeric;
    return _monthNames[value.toLowerCase()];
  }

  int _parseYear(String? rawYear, DateTime today) {
    final parsed = int.tryParse(rawYear ?? '');
    if (parsed == null) return today.year;
    return parsed < 100 ? 2000 + parsed : parsed;
  }

  DateTime? _validPastDate({
    required int? day,
    required int? month,
    required int year,
    required DateTime today,
  }) {
    if (day == null || month == null || month < 1 || month > 12) return null;
    final candidate = DateTime(year, month, day);
    if (candidate.year != year ||
        candidate.month != month ||
        candidate.day != day) {
      return null;
    }
    if (candidate.isAfter(today)) {
      final previousYear = DateTime(year - 1, month, day);
      if (previousYear.year == year - 1 &&
          previousYear.month == month &&
          previousYear.day == day) {
        return previousYear;
      }
    }
    return candidate;
  }

  String _normalize(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
