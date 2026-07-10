import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/services/native_bridge.dart';

void main() {
  test('summarizes reachable WhatsApp Web diagnostics', () {
    final check = WebNetworkCheck.fromMap({
      'host': 'web.whatsapp.com',
      'dns_ok': true,
      'https_ok': true,
      'addresses': ['57.144.43.32'],
      'status_code': 200,
      'error': '',
    });

    expect(check.reachable, isTrue);
    expect(check.summary, contains('reachable'));
  });

  test('summarizes DNS failure for WhatsApp Web diagnostics', () {
    final check = WebNetworkCheck.fromMap({
      'host': 'web.whatsapp.com',
      'dns_ok': false,
      'https_ok': false,
      'addresses': const [],
      'status_code': -1,
      'error': 'DNS failed',
    });

    expect(check.reachable, isFalse);
    expect(check.summary, contains('DNS cannot resolve'));
  });
}
