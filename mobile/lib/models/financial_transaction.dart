class FinancialTransaction {
  const FinancialTransaction({
    required this.id,
    required this.canonicalKey,
    required this.direction,
    required this.amountMinor,
    required this.currency,
    required this.occurredAt,
    required this.sourceConnector,
    required this.createdAt,
    required this.updatedAt,
    this.merchant,
    this.reference,
  });

  final String id;
  final String canonicalKey;
  final String direction;
  final int amountMinor;
  final String currency;
  final int occurredAt;
  final String sourceConnector;
  final String? merchant;
  final String? reference;
  final int createdAt;
  final int updatedAt;

  factory FinancialTransaction.fromJson(Map<String, dynamic> json) {
    return FinancialTransaction(
      id: json['id']?.toString() ?? '',
      canonicalKey: json['canonical_key']?.toString() ?? '',
      direction: json['direction']?.toString() ?? '',
      amountMinor: (json['amount_minor'] as num?)?.toInt() ?? 0,
      currency: json['currency']?.toString() ?? 'INR',
      occurredAt:
          (json['occurred_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      sourceConnector: json['source_connector']?.toString() ?? 'unknown',
      merchant: json['merchant']?.toString(),
      reference: json['reference']?.toString(),
      createdAt:
          (json['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      updatedAt:
          (json['updated_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'canonical_key': canonicalKey,
      'direction': direction,
      'amount_minor': amountMinor,
      'currency': currency,
      'occurred_at': occurredAt,
      'source_connector': sourceConnector,
      'merchant': merchant,
      'reference': reference,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}
