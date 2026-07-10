class Citation {
  final String documentId;
  final String title;
  final int chunkIndex;

  Citation({
    required this.documentId,
    required this.title,
    required this.chunkIndex,
  });

  factory Citation.fromJson(Map<String, dynamic> json) {
    return Citation(
      documentId: json['document_id'] ?? '',
      title: json['title'] ?? '',
      chunkIndex: json['chunk_index'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'document_id': documentId,
      'title': title,
      'chunk_index': chunkIndex,
    };
  }
}

enum MessageSender { user, agent }

class Message {
  final String id;
  final String conversationId;
  final MessageSender sender;
  final String text;
  final DateTime timestamp;
  final List<Citation> citations;

  Message({
    required this.id,
    required this.conversationId,
    required this.sender,
    required this.text,
    required this.timestamp,
    required this.citations,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] ?? '',
      conversationId: json['conversation_id'] ?? '',
      sender: json['sender'] == 'user'
          ? MessageSender.user
          : MessageSender.agent,
      text: json['text'] ?? '',
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
      citations: (json['citations'] as List? ?? [])
          .map((c) => Citation.fromJson(c))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'sender': sender == MessageSender.user ? 'user' : 'agent',
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      'citations': citations.map((c) => c.toJson()).toList(),
    };
  }
}
