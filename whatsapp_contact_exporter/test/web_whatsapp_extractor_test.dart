import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/services/web_whatsapp_extractor.dart';

void main() {
  test('parses mocked WhatsApp Web group data', () {
    final payload = jsonEncode({
      'ready': true,
      'loginRequired': false,
      'source': 'whatsapp_web',
      'groups': [
        {
          'id': '12345@g.us',
          'name': 'Family Group',
          'estimatedMemberCount': 2,
          'members': [
            {
              'id': '919876543210@c.us',
              'name': 'Rahul',
              'phone': '919876543210',
              'isAdmin': true,
            },
            {
              'id': 'abc@lid',
              'name': 'Private Member',
              'phone': '',
              'isAdmin': false,
            },
          ],
        },
      ],
    });

    final result = WebWhatsAppScanResult.fromRawJavaScriptResult(payload);

    expect(result.ready, isTrue);
    expect(result.groups, hasLength(1));
    expect(result.groups.single.name, 'Family Group');
    expect(result.groups.single.members.first.isAdmin, isTrue);
    expect(result.groups.single.members.last.phoneVisibility, 'notVisible');
  });

  test('selects all and custom selected groups', () {
    const groups = [
      WebWhatsAppGroupCandidate(
        whatsappId: 'a@g.us',
        name: 'A',
        estimatedMemberCount: 1,
        members: [],
      ),
      WebWhatsAppGroupCandidate(
        whatsappId: 'b@g.us',
        name: 'B',
        estimatedMemberCount: 2,
        members: [],
      ),
    ];

    final all = WebGroupSelection.selectAll(groups);
    final custom = WebGroupSelection.selectedGroups(groups, {'b@g.us'});

    expect(all, {'a@g.us', 'b@g.us'});
    expect(custom.single.name, 'B');
  });

  test('parses WhatsApp Web login-required state', () {
    final payload = jsonEncode({
      'ready': false,
      'loginRequired': true,
      'source': 'whatsapp_web',
      'error': 'WhatsApp Web login is required.',
      'groups': [],
    });

    final result = WebWhatsAppScanResult.fromRawJavaScriptResult(payload);

    expect(result.ready, isFalse);
    expect(result.loginRequired, isTrue);
    expect(result.groups, isEmpty);
    expect(result.error, contains('login'));
  });

  test('handles null WebView scan result without throwing', () {
    final result = WebWhatsAppScanResult.fromRawJavaScriptResult('null');

    expect(result.ready, isFalse);
    expect(result.groups, isEmpty);
    expect(result.error, contains('no readable data'));
  });
}
