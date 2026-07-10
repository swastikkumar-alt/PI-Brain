import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/models/export_models.dart';
import 'package:whatsapp_contact_exporter/services/export_formatter.dart';

void main() {
  final contact = ExportedContact(
    id: 'c1',
    name: 'Rahul Sharma',
    phone: '+91 98765 43210',
    normalizedPhone: '+919876543210',
    email: 'rahul@example.com',
    source: 'manual',
    tags: const ['friend'],
    createdAt: DateTime.utc(2026),
  );
  final group = WhatsAppGroup(
    id: 'g1',
    name: 'Project Group',
    capturedAt: DateTime.utc(2026),
    sourceAccountLabel: 'com.whatsapp',
  );
  final admin = GroupMember(
    id: 'm1',
    groupId: 'g1',
    displayName: 'Admin One',
    phone: '+91 90000 00001',
    normalizedPhone: '+919000000001',
    role: ContactRole.admin,
    confidence: 'high',
    source: 'whatsapp_accessibility_visible_review',
    whatsappId: '90000000001@c.us',
    phoneVisibility: PhoneVisibility.visible,
    isAdmin: true,
  );
  final member = GroupMember(
    id: 'm2',
    groupId: 'g1',
    displayName: 'Member One',
    phone: '',
    normalizedPhone: '',
    role: ContactRole.member,
    confidence: 'low',
    source: 'whatsapp_accessibility_visible_review',
    whatsappId: 'member@lid',
    phoneVisibility: PhoneVisibility.notVisible,
  );

  test('exports all contacts and group members as CSV', () {
    final csv = ExportFormatter.contactsCsv(
      contacts: [contact],
      groups: [group],
      members: [admin, member],
    );

    expect(csv, contains('Rahul Sharma'));
    expect(csv, contains('Project Group'));
    expect(csv, contains('Admin One'));
    expect(csv, contains('Member One'));
    expect(csv, contains('phone_visibility'));
    expect(csv, contains('is_admin'));
  });

  test('filters admins only and excludes admins', () {
    final adminsOnly = ExportFormatter.contactsCsv(
      contacts: const [],
      groups: [group],
      members: [admin, member],
      roleFilter: MemberRoleFilter.adminsOnly,
    );
    final withoutAdmins = ExportFormatter.contactsCsv(
      contacts: const [],
      groups: [group],
      members: [admin, member],
      roleFilter: MemberRoleFilter.excludeAdmins,
    );

    expect(adminsOnly, contains('Admin One'));
    expect(adminsOnly, isNot(contains('Member One')));
    expect(withoutAdmins, isNot(contains('Admin One')));
    expect(withoutAdmins, contains('Member One'));
  });

  test('deduplicates by normalized phone in CSV', () {
    final duplicateMember = GroupMember(
      id: 'm3',
      groupId: 'g1',
      displayName: 'Rahul Duplicate',
      phone: '+91 98765 43210',
      normalizedPhone: '+919876543210',
      role: ContactRole.member,
      confidence: 'high',
      source: 'whatsapp_accessibility_visible_review',
    );
    final csv = ExportFormatter.contactsCsv(
      contacts: [contact],
      groups: [group],
      members: [duplicateMember],
      dedupe: true,
    );

    expect(RegExp(r'\+91 98765 43210').allMatches(csv), hasLength(1));
  });

  test('exports group rows even when no members are visible', () {
    final csv = ExportFormatter.contactsCsv(
      contacts: const [],
      groups: [group],
      members: const [],
    );
    final rows = csv.split('\n');

    expect(rows, hasLength(2));
    expect(rows.last, contains('whatsapp_group'));
    expect(rows.last, contains('Project Group'));
    expect(rows.last, contains('notVisible'));
  });

  test('exports vCard and JSON', () {
    final vcard = ExportFormatter.vcard(
      contacts: [contact],
      members: [admin, member],
    );
    final json =
        jsonDecode(
              ExportFormatter.exportJson(
                contacts: [contact],
                groups: [group],
                members: [admin, member],
              ),
            )
            as Map<String, dynamic>;

    expect(vcard, contains('BEGIN:VCARD'));
    expect(vcard, contains('FN:Rahul Sharma'));
    expect(json['schema_version'], 1);
    expect(json['format'], 'wa_group_contacts_export');
    expect(json['whatsapp_groups'], hasLength(1));
  });

  test('exports XLSX bytes', () {
    final bytes = ExportFormatter.xlsxBytes(
      contacts: [contact],
      groups: [group],
      members: [admin, member],
    );

    expect(bytes, isNotEmpty);
    expect(bytes.take(2).toList(), [80, 75]);
  });
}
