import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/services/agent_prompt_policy.dart';

void main() {
  group('AgentPromptPolicy', () {
    const policy = AgentPromptPolicy();

    test('routes personal spend and order questions to local grounding', () {
      expect(
        policy.modeFor('how much did I spend yesterday'),
        AgentResponseMode.localGrounded,
      );
      expect(
        policy.modeFor('do i got any orders or packaging in last 48 hours'),
        AgentResponseMode.localGrounded,
      );
    });

    test('routes SMS and spam questions to local grounding', () {
      expect(
        policy.modeFor(
          'did i get some spam calls and messages and can you block those messages from sms',
        ),
        AgentResponseMode.localGrounded,
      );
      expect(
        policy.modeFor('can you read my sms from yesterday'),
        AgentResponseMode.localGrounded,
      );
    });

    test('does not force general questions through local memory', () {
      expect(
        policy.modeFor('what is photosynthesis'),
        AgentResponseMode.generalAssistant,
      );
      expect(
        policy.modeFor('write a professional email saying I am sick'),
        AgentResponseMode.generalAssistant,
      );
      expect(
        policy.modeFor('formalize this: sir, i am sick and not come tomm'),
        AgentResponseMode.generalAssistant,
      );
    });

    test('does not treat message sending commands as RAG questions', () {
      expect(
        policy.modeFor(
          'message 9458420654 that sir, i am sick and not come tomm formalize it on whatsapp',
        ),
        AgentResponseMode.generalAssistant,
      );
    });

    test('general prompt does not contain the old local-memory refusal', () {
      final prompt = policy.buildSystemPrompt(
        userMessage: 'what is photosynthesis',
        retrievedContext: '',
        fileContext: '',
      );

      expect(prompt, isNot(contains('sufficient local memory files')));
      expect(prompt, contains('answer normally'));
    });

    test('local prompt asks for missing source instead of hallucinating', () {
      final prompt = policy.buildSystemPrompt(
        userMessage: 'how much did I spend yesterday',
        retrievedContext: '',
        fileContext: '',
      );

      expect(prompt, contains('local-data reasoning core'));
      expect(prompt, contains('which data source must be connected'));
    });
  });
}
