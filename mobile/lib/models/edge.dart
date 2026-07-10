class Edge {
  final String id;
  final String sourceId;
  final String targetId;
  final String relationshipType;
  final double confidenceScore;
  final int validFrom;
  final int? validUntil;

  Edge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.relationshipType,
    this.confidenceScore = 1.0,
    required this.validFrom,
    this.validUntil,
  });

  factory Edge.fromJson(Map<String, dynamic> json) {
    return Edge(
      id: json['id'] ?? '',
      sourceId: json['source_id'] ?? '',
      targetId: json['target_id'] ?? '',
      relationshipType: json['relationship_type'] ?? '',
      confidenceScore: (json['confidence_score'] as num?)?.toDouble() ?? 1.0,
      validFrom:
          (json['valid_from'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      validUntil: (json['valid_until'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'source_id': sourceId,
      'target_id': targetId,
      'relationship_type': relationshipType,
      'confidence_score': confidenceScore,
      'valid_from': validFrom,
      'valid_until': validUntil,
    };
  }
}
