import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/services/phone_normalizer.dart';

void main() {
  test('normalizes explicit international numbers', () {
    expect(PhoneNormalizer.normalize('+91 98765-43210'), '+919876543210');
    expect(PhoneNormalizer.normalize('0091 98765 43210'), '+919876543210');
  });

  test('keeps local numbers country-agnostic', () {
    expect(PhoneNormalizer.normalize('(987) 654-3210'), '9876543210');
  });

  test('rejects short non-phone fragments', () {
    expect(PhoneNormalizer.normalize('123'), isEmpty);
    expect(PhoneNormalizer.normalize('abc'), isEmpty);
  });
}
