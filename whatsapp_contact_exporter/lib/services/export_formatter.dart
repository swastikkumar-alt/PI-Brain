import 'dart:convert';

import 'package:excel/excel.dart';

import '../models/export_models.dart';

class ExportFormatter {
  const ExportFormatter._();

  static String contactsCsv({
    required Iterable<ExportedContact> contacts,
    required Iterable<WhatsAppGroup> groups,
    required Iterable<GroupMember> members,
    MemberRoleFilter roleFilter = MemberRoleFilter.all,
    bool dedupe = false,
    bool includeRoleColumns = true,
  }) {
    return contactRows(
      contacts: contacts,
      groups: groups,
      members: members,
      roleFilter: roleFilter,
      dedupe: dedupe,
      includeRoleColumns: includeRoleColumns,
    ).map(_csvRow).join('\n');
  }

  static List<List<String>> contactRows({
    required Iterable<ExportedContact> contacts,
    required Iterable<WhatsAppGroup> groups,
    required Iterable<GroupMember> members,
    MemberRoleFilter roleFilter = MemberRoleFilter.all,
    bool dedupe = false,
    bool includeRoleColumns = true,
  }) {
    final header = [
      'type',
      'name',
      'phone',
      'phone_visibility',
      'email',
      'source',
      'group',
      'whatsapp_id',
      'confidence',
      'tags',
    ];
    if (includeRoleColumns) {
      header.insertAll(8, ['role', 'is_admin']);
    }

    final rows = <List<String>>[header];
    final groupNames = {for (final group in groups) group.id: group.name};
    final seen = <String>{};

    void addRow(List<String> row, String dedupeKey) {
      if (dedupe && dedupeKey.isNotEmpty && !seen.add(dedupeKey)) {
        return;
      }
      rows.add(row);
    }

    for (final contact in contacts) {
      final key = _dedupeKey(
        contact.normalizedPhone,
        contact.email,
        contact.name,
      );
      addRow([
        'contact',
        contact.name,
        contact.phone,
        contact.normalizedPhone.isEmpty ? 'notVisible' : 'visible',
        contact.email,
        contact.source,
        '',
        '',
        if (includeRoleColumns) ...['', ''],
        'high',
        contact.tags.join('|'),
      ], key);
    }

    for (final group in groups) {
      addRow([
        'whatsapp_group',
        group.name,
        '',
        PhoneVisibility.notVisible.name,
        '',
        group.sourceAccountLabel.ifEmpty(() => 'whatsapp_group'),
        group.name,
        group.whatsappId,
        if (includeRoleColumns) ...['', ''],
        'group',
        'group',
      ], 'group:${group.id}');
    }

    for (final member in _filterMembers(members, roleFilter)) {
      final key = _dedupeKey(
        member.normalizedPhone,
        '',
        '${member.displayName}:${member.groupId}',
      );
      addRow([
        'whatsapp_group_member',
        member.displayName,
        member.phone,
        member.phoneVisibility.name,
        '',
        member.source,
        groupNames[member.groupId] ?? '',
        member.whatsappId,
        if (includeRoleColumns) ...[
          member.role.name,
          member.isAdmin ? 'true' : 'false',
        ],
        member.confidence,
        '',
      ], key);
    }

    return rows;
  }

  static List<int> xlsxBytes({
    required Iterable<ExportedContact> contacts,
    required Iterable<WhatsAppGroup> groups,
    required Iterable<GroupMember> members,
    MemberRoleFilter roleFilter = MemberRoleFilter.all,
    bool dedupe = false,
    bool includeRoleColumns = true,
  }) {
    final workbook = Excel.createExcel();
    const sheetName = 'WA Groups';
    final sheet = workbook[sheetName];
    workbook.setDefaultSheet(sheetName);
    if (workbook.sheets.containsKey('Sheet1')) {
      workbook.delete('Sheet1');
    }
    for (final row in contactRows(
      contacts: contacts,
      groups: groups,
      members: members,
      roleFilter: roleFilter,
      dedupe: dedupe,
      includeRoleColumns: includeRoleColumns,
    )) {
      sheet.appendRow(row.map((value) => TextCellValue(value)).toList());
    }
    return workbook.save() ?? const <int>[];
  }

  static String vcard({
    required Iterable<ExportedContact> contacts,
    required Iterable<GroupMember> members,
    MemberRoleFilter roleFilter = MemberRoleFilter.all,
  }) {
    final lines = <String>[];
    for (final contact in contacts) {
      if (contact.phone.isEmpty && contact.email.isEmpty) {
        continue;
      }
      _appendVcard(
        lines,
        name: contact.name,
        phone: contact.phone,
        email: contact.email,
        note: 'source:${contact.source}',
      );
    }
    for (final member in _filterMembers(members, roleFilter)) {
      if (member.phone.isEmpty) {
        continue;
      }
      _appendVcard(
        lines,
        name: member.displayName,
        phone: member.phone,
        email: '',
        note:
            'source:${member.source};role:${member.role.name};group:${member.groupId}',
      );
    }
    return lines.join('\n');
  }

  static String exportJson({
    required Iterable<ExportedContact> contacts,
    required Iterable<WhatsAppGroup> groups,
    required Iterable<GroupMember> members,
    Iterable<ExtractionRun> extractionRuns = const [],
  }) {
    final groupMembers = <String, List<GroupMember>>{};
    for (final member in members) {
      groupMembers.putIfAbsent(member.groupId, () => []).add(member);
    }
    final payload = {
      'schema_version': 1,
      'format': 'wa_group_contacts_export',
      'producer': 'WA Group Extractor',
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'extraction_runs': extractionRuns.map((run) => run.toJson()).toList(),
      'contacts': contacts.map((contact) => contact.toJson()).toList(),
      'whatsapp_groups': groups
          .map(
            (group) => {
              ...group.toJson(),
              'members':
                  groupMembers[group.id]
                      ?.map((member) => member.toJson())
                      .toList() ??
                  const [],
            },
          )
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Iterable<GroupMember> _filterMembers(
    Iterable<GroupMember> members,
    MemberRoleFilter filter,
  ) {
    return members.where((member) {
      return switch (filter) {
        MemberRoleFilter.all => true,
        MemberRoleFilter.adminsOnly => member.role == ContactRole.admin,
        MemberRoleFilter.excludeAdmins => member.role != ContactRole.admin,
      };
    });
  }

  static String _csvRow(List<String> columns) {
    return columns.map(_escapeCsv).join(',');
  }

  static String _escapeCsv(String value) {
    final escaped = value.replaceAll('"', '""');
    if (escaped.contains(',') ||
        escaped.contains('"') ||
        escaped.contains('\n') ||
        escaped.contains('\r')) {
      return '"$escaped"';
    }
    return escaped;
  }

  static String _dedupeKey(String phone, String email, String name) {
    if (phone.isNotEmpty) {
      return 'phone:$phone';
    }
    if (email.isNotEmpty) {
      return 'email:${email.toLowerCase()}';
    }
    return 'name:${name.toLowerCase()}';
  }

  static void _appendVcard(
    List<String> lines, {
    required String name,
    required String phone,
    required String email,
    required String note,
  }) {
    final safeName = _escapeVcard(
      name.isEmpty ? phone.ifEmpty(() => email) : name,
    );
    lines
      ..add('BEGIN:VCARD')
      ..add('VERSION:3.0')
      ..add('FN:$safeName');
    if (phone.isNotEmpty) {
      lines.add('TEL;TYPE=CELL:${_escapeVcard(phone)}');
    }
    if (email.isNotEmpty) {
      lines.add('EMAIL:${_escapeVcard(email)}');
    }
    if (note.isNotEmpty) {
      lines.add('NOTE:${_escapeVcard(note)}');
    }
    lines.add('END:VCARD');
  }

  static String _escapeVcard(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .trim();
  }
}

extension _StringFallback on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}
