class SyncEvent {
  final String eventId;
  final String mutationType; // INSERT, UPDATE, DELETE
  final String targetTable; // entities, edges, memories
  final String payload; // JSON representation encrypted base64
  final String status; // PENDING, SYNCED, FAILED
  final String? contentHash;

  SyncEvent({
    required this.eventId,
    required this.mutationType,
    required this.targetTable,
    required this.payload,
    this.status = 'PENDING',
    this.contentHash,
  });

  factory SyncEvent.fromJson(Map<String, dynamic> json) {
    return SyncEvent(
      eventId: json['event_id'] ?? '',
      mutationType: json['mutation_type'] ?? '',
      targetTable: json['target_table'] ?? '',
      payload: json['payload'] ?? '',
      status: json['status'] ?? 'PENDING',
      contentHash: json['content_hash'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'mutation_type': mutationType,
      'target_table': targetTable,
      'payload': payload,
      'status': status,
      'content_hash': contentHash,
    };
  }
}
