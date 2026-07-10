import 'package:flutter_test/flutter_test.dart';
import 'package:pie_mobile/services/datasource_connector_registry.dart';

void main() {
  test('routes each datasource connector to the correct ingestion mode', () {
    final pdf = datasourceConnectorById('local_pdf_scanner');
    final gmail = datasourceConnectorById('gmail_notifications');
    final whatsapp = datasourceConnectorById('whatsapp_context');
    final sms = datasourceConnectorById('sms_messages');
    final health = datasourceConnectorById('health_connect');
    final calls = datasourceConnectorById('call_logs');

    expect(pdf.sourceId, 'files');
    expect(pdf.mode, DatasourceConnectorMode.fileImport);

    expect(gmail.sourceId, 'gmail_notifications');
    expect(gmail.mode, DatasourceConnectorMode.notificationStream);

    expect(whatsapp.sourceId, 'whatsapp_context');
    expect(whatsapp.mode, DatasourceConnectorMode.notificationStream);

    expect(sms.sourceId, 'sms_messages');
    expect(sms.mode, DatasourceConnectorMode.nativeSmsImport);

    expect(health.sourceId, 'health_connect');
    expect(health.mode, DatasourceConnectorMode.healthConnect);

    expect(calls.sourceId, 'call_logs');
    expect(calls.mode, DatasourceConnectorMode.nativeCallLogImport);
  });
}
