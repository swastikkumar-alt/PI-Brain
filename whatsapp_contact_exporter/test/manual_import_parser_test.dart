import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/services/manual_import_parser.dart';

void main() {
  final parser = ManualImportParser();

  test('parses pasted name and phone rows', () {
    final contacts = parser.parseContacts('Rahul Sharma, +91 98765 43210');

    expect(contacts, hasLength(1));
    expect(contacts.single.name, 'Rahul Sharma');
    expect(contacts.single.normalizedPhone, '+919876543210');
  });

  test('parses vCard contacts', () {
    final contacts = parser.parseContacts('''
BEGIN:VCARD
VERSION:3.0
FN:Priya Singh
TEL;TYPE=CELL:+1 415 555 0101
EMAIL:priya@example.com
END:VCARD
''');

    expect(contacts, hasLength(1));
    expect(contacts.single.name, 'Priya Singh');
    expect(contacts.single.email, 'priya@example.com');
  });

  test('deduplicates repeated manual phone rows', () {
    final contacts = parser.parseContacts('''
Rahul, +91 98765 43210
Rahul Sharma, +91 98765 43210
''');

    expect(contacts, hasLength(1));
  });
}
