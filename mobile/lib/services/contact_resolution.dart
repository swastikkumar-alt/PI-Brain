import '../models/phone_action.dart';

class ContactResolution {
  const ContactResolution({
    this.selected,
    this.candidates = const [],
    this.reason,
  });

  final ContactCandidate? selected;
  final List<ContactCandidate> candidates;
  final String? reason;

  bool get isResolved => selected != null;
  bool get needsDisambiguation => selected == null && candidates.isNotEmpty;
  bool get isBlocked => selected == null && !needsDisambiguation;
}

class ContactResolutionEngine {
  const ContactResolutionEngine();

  ContactResolution resolve({
    required String query,
    required List<ContactCandidate> candidates,
  }) {
    final normalizedQuery = _normalizeText(query);
    if (normalizedQuery.isEmpty) {
      return const ContactResolution(reason: 'Recipient is empty.');
    }

    if (candidates.isEmpty) {
      return ContactResolution(reason: 'No contact matched "$query".');
    }

    final exactNameMatches = candidates
        .where(
          (candidate) =>
              _normalizeText(candidate.displayName) == normalizedQuery,
        )
        .toList();
    if (exactNameMatches.length == 1) {
      return ContactResolution(selected: exactNameMatches.single);
    }
    if (exactNameMatches.length > 1) {
      return ContactResolution(candidates: exactNameMatches);
    }

    final containsMatches = candidates
        .where(
          (candidate) =>
              _normalizeText(candidate.displayName).contains(normalizedQuery),
        )
        .toList();
    if (containsMatches.length == 1) {
      return ContactResolution(selected: containsMatches.single);
    }
    if (containsMatches.length > 1) {
      return ContactResolution(candidates: containsMatches);
    }

    final fuzzyMatches = _rankFuzzyMatches(
      normalizedQuery: normalizedQuery,
      candidates: candidates,
    );
    if (fuzzyMatches.isNotEmpty) {
      return ContactResolution(candidates: fuzzyMatches);
    }

    if (candidates.length == 1) {
      return ContactResolution(selected: candidates.single);
    }

    return ContactResolution(candidates: candidates);
  }

  List<ContactCandidate> _rankFuzzyMatches({
    required String normalizedQuery,
    required List<ContactCandidate> candidates,
  }) {
    if (normalizedQuery.length < 3) return const [];

    final scored = <_ScoredContact>[];
    for (final candidate in candidates) {
      final normalizedName = _normalizeText(candidate.displayName);
      if (normalizedName.isEmpty) continue;

      final nameScore = _similarity(normalizedQuery, normalizedName);
      final tokenScore = normalizedName
          .split(' ')
          .map((token) => _similarity(normalizedQuery, token))
          .fold<double>(0, (best, score) => score > best ? score : best);
      final score = nameScore > tokenScore ? nameScore : tokenScore;
      if (score >= 0.68) {
        scored.add(_ScoredContact(candidate, score));
      }
    }

    if (scored.isEmpty) return const [];
    scored.sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first.score;
    return scored
        .where((item) => item.score >= best - 0.08)
        .take(5)
        .map((item) => item.contact)
        .toList();
  }

  double _similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final distance = _levenshtein(a, b);
    final longest = a.length > b.length ? a.length : b.length;
    return 1 - (distance / longest);
  }

  int _levenshtein(String a, String b) {
    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);

    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        final deletion = previous[j + 1] + 1;
        final insertion = current[j] + 1;
        final substitution = previous[j] + cost;
        current[j + 1] = [
          deletion,
          insertion,
          substitution,
        ].reduce((min, value) => value < min ? value : min);
      }
      previous.setAll(0, current);
    }

    return previous[b.length];
  }

  String _normalizeText(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9+ ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _ScoredContact {
  const _ScoredContact(this.contact, this.score);

  final ContactCandidate contact;
  final double score;
}
