import '../models/entity.dart';
import '../models/message.dart';
import 'local_device_insight_service.dart';
import 'spending_insight_service.dart';

class GroundedAnswer {
  const GroundedAnswer({
    required this.answer,
    required this.evidence,
    required this.citations,
  });

  final String answer;
  final List<Entity> evidence;
  final List<Citation> citations;
}

class LocalQuestionRouter {
  LocalQuestionRouter({
    SpendingInsightService? spendingInsight,
    LocalDeviceInsightService? localDeviceInsight,
  }) : _spendingInsight = spendingInsight ?? SpendingInsightService(),
       _localDeviceInsight = localDeviceInsight ?? LocalDeviceInsightService();

  final SpendingInsightService _spendingInsight;
  final LocalDeviceInsightService _localDeviceInsight;

  Future<GroundedAnswer?> answer(String query) async {
    final spending = await _spendingInsight.answerIfSupported(query);
    if (spending != null) {
      return GroundedAnswer(
        answer: spending.answer,
        evidence: const [],
        citations: [
          for (
            var index = 0;
            index < spending.transactions.length && index < 10;
            index++
          )
            Citation(
              documentId: spending.transactions[index].entityId,
              title:
                  'Spend evidence (${spending.transactions[index].sourceConnector})',
              chunkIndex: index,
            ),
        ],
      );
    }

    final local = await _localDeviceInsight.answerIfSupported(query);
    if (local != null) {
      return GroundedAnswer(
        answer: local.answer,
        evidence: local.evidence,
        citations: [
          for (
            var index = 0;
            index < local.evidence.length && index < 10;
            index++
          )
            Citation(
              documentId: local.evidence[index].id,
              title:
                  'Evidence (${local.evidence[index].sourceConnector ?? 'unknown'})',
              chunkIndex: index,
            ),
        ],
      );
    }

    return null;
  }
}
