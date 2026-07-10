import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pie_mobile/models/detected_app.dart';
import 'package:pie_mobile/models/entity.dart';
import 'package:pie_mobile/models/message.dart';
import 'package:pie_mobile/views/chat_view.dart';
import 'package:pie_mobile/views/dashboard_view.dart';
import 'package:pie_mobile/views/intro_view.dart';

void main() {
  testWidgets('Intro screen explains PIE capabilities', (
    WidgetTester tester,
  ) async {
    var continued = false;
    await tester.pumpWidget(
      MaterialApp(
        home: IntroView(
          onContinue: () async {
            continued = true;
          },
        ),
      ),
    );

    expect(find.text('PIE Mobile'), findsOneWidget);
    expect(find.text('Ask about local context'), findsOneWidget);
    expect(find.text('Draft before sending'), findsOneWidget);
    expect(find.text('Approval and safety'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    expect(find.text('Continue to Home'), findsOneWidget);
    await tester.tap(find.text('Continue to Home'));
    await tester.pump();

    expect(continued, isTrue);
  });

  testWidgets('Dashboard view smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: DashboardView())),
    );
    await tester.pump(const Duration(milliseconds: 800));

    // Verify that the DashboardView is loaded
    expect(find.byType(DashboardView), findsOneWidget);

    // Verify navigation tabs exist
    expect(find.byIcon(Icons.dashboard_customize_outlined), findsOneWidget);
    expect(find.text('Mentor'), findsNothing);
    expect(find.byIcon(Icons.self_improvement_outlined), findsNothing);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.inventory_2_outlined), findsWidgets);
    expect(find.text('Phone Agent'), findsNothing);
    expect(find.text('Chat Agent'), findsNothing);
    expect(find.text('Agent'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.smart_toy_outlined));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Device Intelligence'), findsNothing);
    expect(find.text('Samsung Health'), findsNothing);
    expect(find.text('Wellbeing'), findsNothing);
    expect(find.text('Parental'), findsNothing);
  });

  testWidgets('Evidence accordion is collapsed and opens detail sheet', (
    WidgetTester tester,
  ) async {
    final entity = Entity(
      id: 'sms_1',
      entityType: 'message',
      sourceConnector: 'SMS',
      content: 'Received SMS\nFrom/To: BANK\n\nA/c debited by Rs 100.',
      createdAt: DateTime(2026, 7, 8, 12).millisecondsSinceEpoch,
      updatedAt: DateTime(2026, 7, 8, 12).millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EvidenceAccordion(
            citations: [
              Citation(
                documentId: 'sms_1',
                title: 'Spend evidence (SMS)',
                chunkIndex: 0,
              ),
            ],
            evidenceLoader: (_) async => [entity],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Evidence (1)'), findsOneWidget);
    expect(find.textContaining('A/c debited'), findsNothing);

    await tester.tap(find.text('Evidence (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A/c debited'), findsOneWidget);

    await tester.tap(find.text('Spend evidence (SMS)').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy evidence'), findsOneWidget);
  });

  testWidgets('Image handoff sheet shows installed AI app and copy action', (
    WidgetTester tester,
  ) async {
    var openedApp = '';
    var copied = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageHandoffSheet(
            reason: 'Backend image generation is not configured.',
            prompt: 'generate image of a clean dashboard',
            apps: const [
              DetectedApp(
                id: 'gemini',
                name: 'Gemini',
                packageName: 'com.google.android.apps.bard',
                installed: true,
                capability: 'Image handoff',
                status: 'Installed',
                icon: Icons.auto_awesome,
              ),
              DetectedApp(
                id: 'chatgpt',
                name: 'ChatGPT',
                packageName: 'com.openai.chatgpt',
                installed: false,
                capability: 'Image handoff',
                status: 'Not installed',
                icon: Icons.smart_toy_outlined,
              ),
            ],
            onOpenApp: (appId) async {
              openedApp = appId;
            },
            onCopyPrompt: () async {
              copied = true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Continue Image Generation'), findsOneWidget);
    expect(find.text('Open Gemini'), findsOneWidget);
    expect(find.text('ChatGPT not installed'), findsOneWidget);

    await tester.tap(find.text('Open Gemini'));
    await tester.pump();
    expect(openedApp, 'gemini');

    await tester.tap(find.text('Copy Prompt'));
    await tester.pump();
    expect(copied, isTrue);
  });
}
