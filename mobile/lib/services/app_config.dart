class AppConfig {
  static const gatewayBaseUrl = String.fromEnvironment(
    'PIE_GATEWAY_URL',
    defaultValue: 'http://10.0.2.2:8000/api/v1',
  );

  static const ollamaGenerateUrl = String.fromEnvironment(
    'PIE_OLLAMA_URL',
    defaultValue: 'http://10.0.2.2:11434/api/generate',
  );

  static const deviceId = String.fromEnvironment(
    'PIE_DEVICE_ID',
    defaultValue: 'local_flutter_node',
  );

  static const gatewayBearerToken = String.fromEnvironment(
    'PIE_GATEWAY_BEARER_TOKEN',
  );

  static const azureOpenAIChatEndpoint = String.fromEnvironment(
    'PIE_AZURE_OPENAI_CHAT_ENDPOINT',
  );

  static const azureOpenAIApiKey = String.fromEnvironment(
    'PIE_AZURE_OPENAI_API_KEY',
  );

  static const maxAttachmentBytes = int.fromEnvironment(
    'PIE_MAX_ATTACHMENT_BYTES',
    defaultValue: 10485760,
  );

  static const maxExtractedTextChars = int.fromEnvironment(
    'PIE_MAX_EXTRACTED_TEXT_CHARS',
    defaultValue: 120000,
  );

  static const maxRagContextChars = int.fromEnvironment(
    'PIE_MAX_RAG_CONTEXT_CHARS',
    defaultValue: 24000,
  );

  static const maxIngestChunks = int.fromEnvironment(
    'PIE_MAX_INGEST_CHUNKS',
    defaultValue: 500,
  );

  static bool get hasAzureOpenAIConfig =>
      azureOpenAIChatEndpoint.isNotEmpty && azureOpenAIApiKey.isNotEmpty;
}
