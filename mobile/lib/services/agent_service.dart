import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/entity.dart';
import '../models/edge.dart';
import '../models/sync_event.dart';
import '../models/message.dart';
import 'app_config.dart';
import 'agent_prompt_policy.dart';
import 'database_service.dart';
import 'gateway_settings_service.dart';
import 'local_query_context_service.dart';
import 'local_device_insight_service.dart';
import 'spending_insight_service.dart';

class AgentService {
  final DatabaseService _db = DatabaseService.instance;
  final SpendingInsightService _spendingInsight = SpendingInsightService();
  final LocalDeviceInsightService _localDeviceInsight =
      LocalDeviceInsightService();
  final LocalQueryContextService _localQueryContext =
      LocalQueryContextService();
  final AgentPromptPolicy _promptPolicy = const AgentPromptPolicy();
  final _uuid = const Uuid();
  final _gatewaySettings = GatewaySettingsService.instance;

  String hostUrl = AppConfig.gatewayBaseUrl;
  bool useLocalOllamaDirect = false;
  String ollamaUrl = AppConfig.ollamaGenerateUrl;

  Future<Map<String, String>> _jsonHeaders() async {
    final token = await _gatewaySettings.getBearerToken();

    return {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<String> _gatewayUrl() async {
    if (hostUrl != AppConfig.gatewayBaseUrl) return hostUrl;
    return _gatewaySettings.getGatewayBaseUrl();
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) return value;
    return '${value.substring(0, maxChars)}\n\n[Truncated to $maxChars characters]';
  }

  // Local File Memories
  Future<File> _getLocalFile(String filename) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = p.basename(filename);
    return File(p.join(dir.path, safeName));
  }

  Future<void> writeToLocalFileMemory(String filename, String content) async {
    final file = await _getLocalFile(filename);
    await file.writeAsString(content);
  }

  Future<String> readLocalFileMemory(String filename) async {
    try {
      final file = await _getLocalFile(filename);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (error, stackTrace) {
      developer.log(
        'Failed to read local memory file.',
        name: 'AgentService',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return '';
  }

  // --- Conversational agent with model-required response generation ---
  Future<Message> thinkAndRespond(
    String userMessage,
    String conversationId, [
    File? attachedFile,
  ]) async {
    // 1. Save user query message
    final userMsgId = _uuid.v4();
    final userMsg = Message(
      id: userMsgId,
      conversationId: conversationId,
      sender: MessageSender.user,
      text: userMessage,
      timestamp: DateTime.now(),
      citations: [],
    );
    await _db.insertMessage(userMsg);

    final spendingInsight = await _spendingInsight.answerIfSupported(
      userMessage,
    );
    if (spendingInsight != null) {
      final citations = <Citation>[
        for (
          var index = 0;
          index < spendingInsight.transactions.length && index < 10;
          index++
        )
          Citation(
            documentId: spendingInsight.transactions[index].entityId,
            title:
                'Spend evidence (${spendingInsight.transactions[index].sourceConnector})',
            chunkIndex: index,
          ),
      ];
      final agentMsg = Message(
        id: _uuid.v4(),
        conversationId: conversationId,
        sender: MessageSender.agent,
        text: spendingInsight.answer,
        timestamp: DateTime.now(),
        citations: citations,
      );
      await _db.insertMessage(agentMsg);
      return agentMsg;
    }

    final localDeviceInsight = await _localDeviceInsight.answerIfSupported(
      userMessage,
    );
    if (localDeviceInsight != null) {
      final citations = <Citation>[
        for (
          var index = 0;
          index < localDeviceInsight.evidence.length && index < 10;
          index++
        )
          Citation(
            documentId: localDeviceInsight.evidence[index].id,
            title:
                'Local evidence (${localDeviceInsight.evidence[index].sourceConnector ?? 'unknown'})',
            chunkIndex: index,
          ),
      ];
      final agentMsg = Message(
        id: _uuid.v4(),
        conversationId: conversationId,
        sender: MessageSender.agent,
        text: localDeviceInsight.answer,
        timestamp: DateTime.now(),
        citations: citations,
      );
      await _db.insertMessage(agentMsg);
      return agentMsg;
    }

    // 2. Build grounded local evidence context and repair stale search index if needed.
    final localContext = await _localQueryContext.build(userMessage);
    final contextBuffer = StringBuffer()..writeln(localContext.contextText);
    final citations = <Citation>[...localContext.citations];

    // 3. Retrieve memories and local system profile details
    final userProfile = await readLocalFileMemory('USER.md');
    final coreMemoryNotes = await readLocalFileMemory('MEMORY.md');

    contextBuffer.writeln('\n=== SYSTEM PROFILE FILE ===');
    contextBuffer.writeln('Profile Facts: $userProfile');
    contextBuffer.writeln('Memory Notes: $coreMemoryNotes');

    // 4. Process optional attached file
    String fileContext = '';
    String? base64Image;

    if (attachedFile != null) {
      final fileSize = await attachedFile.length();
      final lowerPath = attachedFile.path.toLowerCase();
      if (fileSize > AppConfig.maxAttachmentBytes) {
        fileContext =
            'User attached a file that was skipped because it exceeds the configured ${AppConfig.maxAttachmentBytes} byte limit.\n\n';
      } else if (lowerPath.endsWith('.pdf')) {
        final PdfDocument document = PdfDocument(
          inputBytes: await attachedFile.readAsBytes(),
        );
        try {
          final text = _truncate(
            PdfTextExtractor(document).extractText(),
            AppConfig.maxExtractedTextChars,
          );
          fileContext = 'User attached a PDF document. Content:\n$text\n\n';
        } finally {
          document.dispose();
        }
      } else if (lowerPath.endsWith('.txt') || lowerPath.endsWith('.eml')) {
        final text = _truncate(
          await attachedFile.readAsString(),
          AppConfig.maxExtractedTextChars,
        );
        fileContext = 'User attached a text file. Content:\n$text\n\n';
      } else if (lowerPath.endsWith('.png') ||
          lowerPath.endsWith('.jpg') ||
          lowerPath.endsWith('.jpeg')) {
        final bytes = await attachedFile.readAsBytes();
        base64Image = base64Encode(bytes);
      }
    }

    if (localContext.noEvidenceAnswer != null && attachedFile == null) {
      final agentMsg = Message(
        id: _uuid.v4(),
        conversationId: conversationId,
        sender: MessageSender.agent,
        text: localContext.noEvidenceAnswer!,
        timestamp: DateTime.now(),
        citations: const [],
      );
      await _db.insertMessage(agentMsg);
      return agentMsg;
    }

    // 5. Structure prompt and instruct LLM
    final systemPrompt = _promptPolicy.buildSystemPrompt(
      userMessage: userMessage,
      retrievedContext: _truncate(
        contextBuffer.toString(),
        AppConfig.maxRagContextChars,
      ),
      fileContext: fileContext,
    );

    String agentText = '';
    try {
      if (useLocalOllamaDirect) {
        final response = await http
            .post(
              Uri.parse(ollamaUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'model': 'hermes',
                'prompt': '$systemPrompt\n\nUser: $userMessage\nAgent:',
                'stream': false,
              }),
            )
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          agentText = data['response'] ?? '';
        } else {
          throw StateError(
            'Local model returned ${response.statusCode}: ${response.body}',
          );
        }
      } else if (AppConfig.hasAzureOpenAIConfig) {
        dynamic userMessageContent;
        if (base64Image != null) {
          userMessageContent = [
            {'type': 'text', 'text': userMessage},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
            },
          ];
        } else {
          userMessageContent = userMessage;
        }

        final response = await http
            .post(
              Uri.parse(AppConfig.azureOpenAIChatEndpoint),
              headers: {
                'Content-Type': 'application/json',
                'api-key': AppConfig.azureOpenAIApiKey,
              },
              body: jsonEncode({
                'messages': [
                  {'role': 'system', 'content': systemPrompt},
                  {'role': 'user', 'content': userMessageContent},
                ],
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          agentText = data['choices'][0]['message']['content'] ?? '';
        } else {
          throw StateError(
            'Azure OpenAI returned ${response.statusCode}: ${response.body}',
          );
        }
      } else {
        final response = await http
            .post(
              Uri.parse('${await _gatewayUrl()}/agent/respond'),
              headers: await _jsonHeaders(),
              body: jsonEncode({
                'messages': [
                  {'role': 'system', 'content': systemPrompt},
                  {'role': 'user', 'content': userMessage},
                ],
                'image_base64': ?base64Image,
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          agentText =
              (data['response'] ?? data['message'] ?? data['text'] ?? '')
                  .toString();
        } else {
          throw StateError(
            'PIE backend returned ${response.statusCode}: ${response.body}',
          );
        }
      }
    } catch (error, stackTrace) {
      developer.log(
        'Agent response failed. No local fallback will be used.',
        name: 'AgentService',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    if (agentText.isEmpty) {
      throw StateError('Model returned an empty response.');
    }

    // 7. Extraction & Learning Loop (Update entities, edges and register Sync Ledger events)
    if (userMessage.toLowerCase().contains('i prefer') ||
        userMessage.toLowerCase().contains('my name is')) {
      final preferenceId = _uuid.v4();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // A. Create new Entity node representing user preference
      final prefEntity = Entity(
        id: preferenceId,
        entityType: 'memory',
        sourceConnector: 'chat_agent',
        content: 'User Preference: $userMessage',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      await _db.insertEntity(prefEntity);

      // B. Create connection edge linking user message to preference
      final edgeId = _uuid.v4();
      final prefEdge = Edge(
        id: edgeId,
        sourceId: userMsgId,
        targetId: preferenceId,
        relationshipType: 'DECLARED_PREFERENCE',
        validFrom: timestamp,
      );
      await _db.insertEdge(prefEdge);

      // C. Queue CRDT sync events to ledger for peer syncing
      // We generate chronological sortable event IDs (simulating UUID v7 using epoch timestamp prefix)
      final eventIdV7 =
          '018b1d4c-a3f2-${timestamp.toRadixString(16).padLeft(4, '0')}-9876-000000000000';

      final syncEvent = SyncEvent(
        eventId: eventIdV7,
        mutationType: 'INSERT',
        targetTable: 'entities',
        payload: jsonEncode(prefEntity.toJson()),
        status: 'PENDING',
      );
      await _db.insertSyncEvent(syncEvent);

      // Update local profile files
      final updatedProfile = '$userProfile\n- User Preference: $userMessage';
      await writeToLocalFileMemory('USER.md', updatedProfile);
    }

    // 8. Save agent reply
    final agentMsg = Message(
      id: _uuid.v4(),
      conversationId: conversationId,
      sender: MessageSender.agent,
      text: agentText,
      timestamp: DateTime.now(),
      citations: citations,
    );
    await _db.insertMessage(agentMsg);

    return agentMsg;
  }
}
