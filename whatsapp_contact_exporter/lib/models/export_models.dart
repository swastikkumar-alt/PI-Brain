import 'dart:convert';

enum ContactRole {
  admin,
  member,
  unknown;

  static ContactRole fromStorage(String? value) {
    return ContactRole.values.firstWhere(
      (role) => role.name == value,
      orElse: () => ContactRole.unknown,
    );
  }
}

enum MemberRoleFilter { all, adminsOnly, excludeAdmins }

enum PhoneVisibility {
  visible,
  notVisible;

  static PhoneVisibility fromStorage(String? value) {
    return PhoneVisibility.values.firstWhere(
      (visibility) => visibility.name == value,
      orElse: () => PhoneVisibility.notVisible,
    );
  }
}

enum ExtractionRunStatus {
  running,
  completed,
  failed,
  cancelled;

  static ExtractionRunStatus fromStorage(String? value) {
    return ExtractionRunStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => ExtractionRunStatus.completed,
    );
  }
}

class ExtractionRun {
  const ExtractionRun({
    required this.id,
    required this.source,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.selectedGroupCount,
    required this.memberCount,
    required this.error,
  });

  final String id;
  final String source;
  final ExtractionRunStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final int selectedGroupCount;
  final int memberCount;
  final String error;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'status': status.name,
    'started_at': startedAt.toIso8601String(),
    'finished_at': finishedAt?.toIso8601String() ?? '',
    'selected_group_count': selectedGroupCount,
    'member_count': memberCount,
    'error': error,
  };

  factory ExtractionRun.fromJson(Map<String, Object?> json) {
    return ExtractionRun(
      id: '${json['id'] ?? ''}',
      source: '${json['source'] ?? ''}',
      status: ExtractionRunStatus.fromStorage('${json['status'] ?? ''}'),
      startedAt:
          DateTime.tryParse('${json['started_at'] ?? ''}') ?? DateTime.now(),
      finishedAt: DateTime.tryParse('${json['finished_at'] ?? ''}'),
      selectedGroupCount:
          int.tryParse('${json['selected_group_count'] ?? 0}') ?? 0,
      memberCount: int.tryParse('${json['member_count'] ?? 0}') ?? 0,
      error: '${json['error'] ?? ''}',
    );
  }
}

class ExportedContact {
  const ExportedContact({
    required this.id,
    required this.name,
    required this.phone,
    required this.normalizedPhone,
    required this.email,
    required this.source,
    required this.tags,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String phone;
  final String normalizedPhone;
  final String email;
  final String source;
  final List<String> tags;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'normalized_phone': normalizedPhone,
    'email': email,
    'source': source,
    'tags': tags,
    'created_at': createdAt.toIso8601String(),
  };

  factory ExportedContact.fromJson(Map<String, Object?> json) {
    final tagsValue = json['tags'];
    final parsedTags = tagsValue is String
        ? (jsonDecode(tagsValue) as List<dynamic>).map((tag) => '$tag').toList()
        : tagsValue is List
        ? tagsValue.map((tag) => '$tag').toList()
        : const <String>[];
    return ExportedContact(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      phone: '${json['phone'] ?? ''}',
      normalizedPhone: '${json['normalized_phone'] ?? ''}',
      email: '${json['email'] ?? ''}',
      source: '${json['source'] ?? ''}',
      tags: parsedTags,
      createdAt:
          DateTime.tryParse('${json['created_at'] ?? ''}') ?? DateTime.now(),
    );
  }
}

class WhatsAppGroup {
  const WhatsAppGroup({
    required this.id,
    required this.name,
    required this.capturedAt,
    required this.sourceAccountLabel,
    this.whatsappId = '',
    this.extractionRunId = '',
  });

  final String id;
  final String name;
  final DateTime capturedAt;
  final String sourceAccountLabel;
  final String whatsappId;
  final String extractionRunId;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'captured_at': capturedAt.toIso8601String(),
    'source_account_label': sourceAccountLabel,
    'whatsapp_id': whatsappId,
    'extraction_run_id': extractionRunId,
  };

  factory WhatsAppGroup.fromJson(Map<String, Object?> json) {
    return WhatsAppGroup(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      capturedAt:
          DateTime.tryParse('${json['captured_at'] ?? ''}') ?? DateTime.now(),
      sourceAccountLabel: '${json['source_account_label'] ?? ''}',
      whatsappId: '${json['whatsapp_id'] ?? ''}',
      extractionRunId: '${json['extraction_run_id'] ?? ''}',
    );
  }
}

class GroupMember {
  const GroupMember({
    required this.id,
    required this.groupId,
    required this.displayName,
    required this.phone,
    required this.normalizedPhone,
    required this.role,
    required this.confidence,
    required this.source,
    this.whatsappId = '',
    this.phoneVisibility = PhoneVisibility.visible,
    this.isAdmin = false,
    this.extractionRunId = '',
  });

  final String id;
  final String groupId;
  final String displayName;
  final String phone;
  final String normalizedPhone;
  final ContactRole role;
  final String confidence;
  final String source;
  final String whatsappId;
  final PhoneVisibility phoneVisibility;
  final bool isAdmin;
  final String extractionRunId;

  Map<String, Object?> toJson() => {
    'id': id,
    'group_id': groupId,
    'display_name': displayName,
    'phone': phone,
    'normalized_phone': normalizedPhone,
    'role': role.name,
    'confidence': confidence,
    'source': source,
    'whatsapp_id': whatsappId,
    'phone_visibility': phoneVisibility.name,
    'is_admin': isAdmin ? 1 : 0,
    'extraction_run_id': extractionRunId,
  };

  factory GroupMember.fromJson(Map<String, Object?> json) {
    return GroupMember(
      id: '${json['id'] ?? ''}',
      groupId: '${json['group_id'] ?? ''}',
      displayName: '${json['display_name'] ?? ''}',
      phone: '${json['phone'] ?? ''}',
      normalizedPhone: '${json['normalized_phone'] ?? ''}',
      role: ContactRole.fromStorage('${json['role'] ?? ''}'),
      confidence: '${json['confidence'] ?? ''}',
      source: '${json['source'] ?? ''}',
      whatsappId: '${json['whatsapp_id'] ?? ''}',
      phoneVisibility: PhoneVisibility.fromStorage(
        '${json['phone_visibility'] ?? ''}',
      ),
      isAdmin: _boolFromStorage(json['is_admin']),
      extractionRunId: '${json['extraction_run_id'] ?? ''}',
    );
  }

  static bool _boolFromStorage(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = '$value'.toLowerCase();
    return text == 'true' || text == '1';
  }
}

class ExportRecord {
  const ExportRecord({
    required this.id,
    required this.exportType,
    required this.path,
    required this.rowCount,
    required this.createdAt,
  });

  final String id;
  final String exportType;
  final String path;
  final int rowCount;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'export_type': exportType,
    'path': path,
    'row_count': rowCount,
    'created_at': createdAt.toIso8601String(),
  };

  factory ExportRecord.fromJson(Map<String, Object?> json) {
    return ExportRecord(
      id: '${json['id'] ?? ''}',
      exportType: '${json['export_type'] ?? ''}',
      path: '${json['path'] ?? ''}',
      rowCount: int.tryParse('${json['row_count'] ?? 0}') ?? 0,
      createdAt:
          DateTime.tryParse('${json['created_at'] ?? ''}') ?? DateTime.now(),
    );
  }
}

class CaptureBatch {
  const CaptureBatch({
    required this.groupName,
    required this.sourceAccountLabel,
    required this.capturedAt,
    required this.members,
  });

  final String groupName;
  final String sourceAccountLabel;
  final DateTime capturedAt;
  final List<GroupMember> members;

  factory CaptureBatch.fromJson(Map<String, Object?> json) {
    final rawMembers = json['members'];
    return CaptureBatch(
      groupName: '${json['group_name'] ?? json['groupName'] ?? ''}',
      sourceAccountLabel:
          '${json['source_account_label'] ?? json['sourceAccountLabel'] ?? ''}',
      capturedAt:
          DateTime.tryParse(
            '${json['captured_at'] ?? json['capturedAt'] ?? ''}',
          ) ??
          DateTime.now(),
      members: rawMembers is List
          ? rawMembers
                .whereType<Map>()
                .map(
                  (member) => GroupMember.fromJson(
                    member.map((key, value) => MapEntry('$key', value)),
                  ),
                )
                .toList()
          : const <GroupMember>[],
    );
  }
}
