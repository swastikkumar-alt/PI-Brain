import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
}
