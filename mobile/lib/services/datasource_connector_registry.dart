enum DatasourceConnectorMode {
  fileImport,
  notificationStream,
  nativeSmsImport,
  nativeCallLogImport,
  healthConnect,
}

class DatasourceConnectorDefinition {
  const DatasourceConnectorDefinition({
    required this.id,
    required this.name,
    required this.sourceId,
    required this.sourceConnector,
    required this.mode,
    required this.description,
    required this.actionLabel,
  });

  final String id;
  final String name;
  final String sourceId;
  final String sourceConnector;
  final DatasourceConnectorMode mode;
  final String description;
  final String actionLabel;
}

const datasourceConnectorDefinitions = <DatasourceConnectorDefinition>[
  DatasourceConnectorDefinition(
    id: 'local_pdf_scanner',
    name: 'PDFs and Documents',
    sourceId: 'files',
    sourceConnector: 'PDF',
    mode: DatasourceConnectorMode.fileImport,
    description: 'Pick one or more PDFs. Duplicate content is skipped.',
    actionLabel: 'Import PDFs',
  ),
  DatasourceConnectorDefinition(
    id: 'gmail_notifications',
    name: 'Gmail Notifications',
    sourceId: 'gmail_notifications',
    sourceConnector: 'GMAIL',
    mode: DatasourceConnectorMode.notificationStream,
    description: 'Read Gmail notification summaries after notification access.',
    actionLabel: 'Connect',
  ),
  DatasourceConnectorDefinition(
    id: 'whatsapp_context',
    name: 'WhatsApp Notifications',
    sourceId: 'whatsapp_context',
    sourceConnector: 'CHAT',
    mode: DatasourceConnectorMode.notificationStream,
    description:
        'Read WhatsApp notification context after notification access.',
    actionLabel: 'Connect',
  ),
  DatasourceConnectorDefinition(
    id: 'sms_messages',
    name: 'SMS Messages',
    sourceId: 'sms_messages',
    sourceConnector: 'SMS',
    mode: DatasourceConnectorMode.nativeSmsImport,
    description: 'Import recent SMS locally and skip duplicate messages.',
    actionLabel: 'Import SMS',
  ),
  DatasourceConnectorDefinition(
    id: 'health_connect',
    name: 'Health Connect',
    sourceId: 'health_connect',
    sourceConnector: 'HEALTH',
    mode: DatasourceConnectorMode.healthConnect,
    description: 'Import user-approved steps and sleep records.',
    actionLabel: 'Import Health',
  ),
  DatasourceConnectorDefinition(
    id: 'call_logs',
    name: 'Call Logs',
    sourceId: 'call_logs',
    sourceConnector: 'CALL_LOG',
    mode: DatasourceConnectorMode.nativeCallLogImport,
    description: 'Import missed, incoming and outgoing call metadata locally.',
    actionLabel: 'Import Calls',
  ),
];

DatasourceConnectorDefinition datasourceConnectorById(String id) {
  return datasourceConnectorDefinitions.firstWhere(
    (connector) => connector.id == id,
  );
}
