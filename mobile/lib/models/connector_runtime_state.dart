import '../services/datasource_connector_registry.dart';

class ConnectorRuntimeState {
  ConnectorRuntimeState({required this.definition});

  final DatasourceConnectorDefinition definition;
  String status = 'IDLE';
  String lastSync = 'Never';

  String get statusLabel {
    return switch (status) {
      'SYNCING' => 'Working',
      'SUCCESS' => 'Connected',
      'FAILED' => 'Needs attention',
      'BLOCKED' => 'Permission needed',
      _ => 'Ready',
    };
  }
}
