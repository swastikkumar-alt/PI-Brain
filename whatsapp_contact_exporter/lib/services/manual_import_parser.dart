import '../models/export_models.dart';
import 'phone_normalizer.dart';

class ManualImportParser {
  static final _emailRegex = RegExp(
    r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
    caseSensitive: false,
  );
  static final _phoneRegex = RegExp(r'\+?\d[\d\s().-]{5,}\d');

  List<ExportedContact> parseContacts(
    String input, {
    String source = 'manual',
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return const [];
    }
    if (trimmed.toUpperCase().contains('BEGIN:VCARD')) {
      return _parseVcards(trimmed, source: source);
    }
    return _parseLines(trimmed, source: source);
  }

  List<ExportedContact> _parseVcards(String input, {required String source}) {
    final cards = RegExp(
      r'BEGIN:VCARD([\s\S]*?)END:VCARD',
      caseSensitive: false,
    ).allMatches(input);
    final contacts = <ExportedContact>[];
    var index = 0;
    for (final card in cards) {
      final body = card.group(1) ?? '';
      final name = _firstVcardValue(
        body,
        'FN',
      ).ifEmpty(() => _firstVcardValue(body, 'N'));
      final phone = _firstVcardValue(body, 'TEL');
      final email = _firstVcardValue(body, 'EMAIL');
      if (name.isEmpty && phone.isEmpty && email.isEmpty) {
        continue;
      }
      contacts.add(
        _contact(
          index: index++,
          name: name.ifEmpty(() => phone.ifEmpty(() => email)),
          phone: phone,
          email: email,
          source: source,
          tags: const ['manual_vcard'],
        ),
      );
    }
    return _dedupe(contacts);
  }

  List<ExportedContact> _parseLines(String input, {required String source}) {
    final contacts = <ExportedContact>[];
    var index = 0;
    for (final rawLine in input.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || _isHeader(line)) {
        continue;
      }
      final email = _emailRegex.firstMatch(line)?.group(0) ?? '';
      final phone = _phoneRegex.firstMatch(line)?.group(0) ?? '';
      var name = line;
      if (email.isNotEmpty) {
        name = name.replaceAll(email, ' ');
      }
      if (phone.isNotEmpty) {
        name = name.replaceAll(phone, ' ');
      }
      name = name
          .replaceAll(RegExp(r'[,;\t]+'), ' ')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();
      if (name.isEmpty) {
        name = phone.ifEmpty(() => email);
      }
      if (name.isEmpty && phone.isEmpty && email.isEmpty) {
        continue;
      }
      contacts.add(
        _contact(
          index: index++,
          name: name,
          phone: phone,
          email: email,
          source: source,
          tags: const ['manual_text'],
        ),
      );
    }
    return _dedupe(contacts);
  }

  String _firstVcardValue(String body, String key) {
    final match = RegExp(
      '^$key(?:;[^:]*)?:(.*)\$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(body);
    return (match?.group(1) ?? '')
        .replaceAll(r'\n', ' ')
        .replaceAll(';', ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  ExportedContact _contact({
    required int index,
    required String name,
    required String phone,
    required String email,
    required String source,
    required List<String> tags,
  }) {
    final normalizedPhone = PhoneNormalizer.normalize(phone);
    final key = normalizedPhone.ifEmpty(() => email.ifEmpty(() => name));
    return ExportedContact(
      id: 'manual_${key.hashCode.abs()}_$index',
      name: name,
      phone: phone,
      normalizedPhone: normalizedPhone,
      email: email,
      source: source,
      tags: tags,
      createdAt: DateTime.now(),
    );
  }

  List<ExportedContact> _dedupe(List<ExportedContact> contacts) {
    final seen = <String>{};
    final output = <ExportedContact>[];
    for (final contact in contacts) {
      final key = contact.normalizedPhone.ifEmpty(
        () => contact.email.toLowerCase().ifEmpty(() => contact.name),
      );
      if (seen.add(key)) {
        output.add(contact);
      }
    }
    return output;
  }

  bool _isHeader(String line) {
    final lower = line.toLowerCase();
    return lower.contains('name') &&
        (lower.contains('phone') || lower.contains('email'));
  }
}

extension _StringFallback on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}
