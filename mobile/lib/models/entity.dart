class Entity {
  final String id;
  final String entityType;
  final String? sourceConnector;
  final String? content;
  final String? contentHash;
  final int createdAt;
  final int updatedAt;
  final bool isSynced;

  Entity({
    required this.id,
    required this.entityType,
    this.sourceConnector,
    this.content,
    this.contentHash,
    required this.createdAt,
    required this.updatedAt,
    this.isSynced = false,
  });

  factory Entity.fromJson(Map<String, dynamic> json) {
    return Entity(
      id: json['id'] ?? '',
      entityType: json['entity_type'] ?? '',
      sourceConnector: json['source_connector'],
      content: json['content'],
      contentHash: json['content_hash'],
      createdAt: json['created_at'] is String
          ? DateTime.parse(json['created_at']).millisecondsSinceEpoch
          : (json['created_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
      updatedAt: json['updated_at'] is String
          ? DateTime.parse(json['updated_at']).millisecondsSinceEpoch
          : (json['updated_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
      isSynced: json['is_synced'] == 1 || json['is_synced'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'entity_type': entityType,
      'source_connector': sourceConnector,
      'content': content,
      'content_hash': contentHash,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'is_synced': isSynced ? 1 : 0,
    };
  }
}
