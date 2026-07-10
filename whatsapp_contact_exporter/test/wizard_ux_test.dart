import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_contact_exporter/main.dart';
import 'package:whatsapp_contact_exporter/models/export_models.dart';
import 'package:whatsapp_contact_exporter/services/exporter_database.dart';
import 'package:whatsapp_contact_exporter/services/native_bridge.dart';

void main() {
  testWidgets('launch defaults to phone capture wizard', (tester) async {
    await _pumpHome(tester);

    expect(find.text('Choose source'), findsOneWidget);
    expect(find.text('Phone capture'), findsOneWidget);
    expect(find.text('Advanced bulk scan'), findsOneWidget);
    expect(find.text('Capture from phone'), findsOneWidget);
  });

  testWidgets('accessibility disabled shows enable-only blocked state', (
    tester,
  ) async {
    await _pumpHome(tester);

    expect(find.text('Enable Capture Service'), findsWidgets);
    expect(find.text('Open WhatsApp'), findsNothing);
    expect(find.text('Review Captured Group'), findsNothing);
  });

  testWidgets('saved phone capture shows review CTA and counts', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      accessibilityEnabled: true,
      counts: const ExporterCounts(
        contacts: 4,
        groups: 2,
        groupMembers: 17,
        exports: 0,
      ),
    );

    expect(find.text('2 groups, 17 members'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(find.text('Review Captured Group'), findsWidgets);
    expect(find.text('Review phone visibility'), findsOneWidget);
  });

  testWidgets('web source shows full-screen login CTA when not connected', (
    tester,
  ) async {
    await _pumpHome(tester, accessibilityEnabled: true);

    await tester.tap(find.text('Advanced bulk scan'));
    await tester.pumpAndSettle();

    expect(find.text('Scan WhatsApp Web'), findsOneWidget);
    expect(find.text('Connect WhatsApp Web'), findsOneWidget);
    expect(find.text('Full-screen login'), findsWidgets);
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  bool accessibilityEnabled = false,
  ExporterCounts counts = const ExporterCounts(
    contacts: 0,
    groups: 0,
    groupMembers: 0,
    exports: 0,
  ),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0f766e)),
        useMaterial3: true,
      ),
      home: ExtractorHomePage(
        database: _FakeDatabase(counts),
        bridge: _FakeBridge(accessibilityEnabled),
        enableWebView: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeDatabase extends ExporterDatabase {
  _FakeDatabase(this.countsValue);

  final ExporterCounts countsValue;

  @override
  Future<ExporterCounts> counts() async => countsValue;

  @override
  Future<List<ExportRecord>> exports() async => const [];

  @override
  Future<List<ExtractionRun>> extractionRuns() async => const [];
}

class _FakeBridge extends NativeBridge {
  _FakeBridge(this.accessibilityEnabledValue);

  final bool accessibilityEnabledValue;

  @override
  Future<bool> accessibilityEnabled() async => accessibilityEnabledValue;
}
