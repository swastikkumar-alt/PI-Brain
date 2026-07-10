class Memory {
  final String id;
  final String? entityId;
  final String memoryType; // episodic, semantic, procedural, preference
  final String summary;

  Memory({
    required this.id,
    this.entityId,
    required this.memoryType,
    required this.summary,
  });

  factory Memory.fromJson(Map<String, dynamic> json) {
    return Memory(
      id: json['id'] ?? '',
      entityId: json['entity_id'],
      memoryType: json['memory_type'] ?? 'episodic',
      summary: json['summary'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'entity_id': entityId,
      'memory_type': memoryType,
      'summary': summary,
    };
  }
}
