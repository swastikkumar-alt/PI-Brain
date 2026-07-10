import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'views/dashboard_view.dart';
import 'views/intro_view.dart';
import 'services/database_service.dart';
import 'services/onboarding_service.dart';
import 'services/notification_service.dart';
import 'services/theme_mode_service.dart';
import 'services/local_data_freshness_service.dart';
import 'services/spending_insight_service.dart';

const _localDataSyncTask = 'pie.local_data_sync';
const _localDataSyncUniqueName = 'pie.local_data_sync.periodic';

@pragma('vm:entry-point')
void pieLocalDataSyncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await SpendingInsightService().backfillLedger();
      await DatabaseService.instance.repairSearchIndex();
      return true;
    } catch (error, stackTrace) {
      developer.log(
        'Background local data maintenance failed.',
        name: 'PIEBackgroundSync',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeBackgroundSync();
  await ThemeModeService.instance.load();
  NotificationService.instance.initialize();
  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _initializeBackgroundSync() async {
  if (!Platform.isAndroid) return;
  try {
    await Workmanager().initialize(pieLocalDataSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _localDataSyncUniqueName,
      _localDataSyncTask,
      frequency: const Duration(hours: 4),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(networkType: NetworkType.notRequired),
    );
  } catch (error, stackTrace) {
    developer.log(
      'Failed to register background local data maintenance.',
      name: 'PIEBackgroundSync',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _checkingIntro = true;
  bool _showIntro = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocalDataFreshnessService.instance.startForegroundScheduler();
    LocalDataFreshnessService.instance.refreshAllEnabledIfStale(
      reason: 'app_start',
    );
    _loadIntroState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LocalDataFreshnessService.instance.stopForegroundScheduler();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      LocalDataFreshnessService.instance.refreshAllEnabledIfStale(
        reason: 'app_resume',
      );
    }
  }

  Future<void> _loadIntroState() async {
    final hasSeenIntro = await OnboardingService.instance.hasSeenIntro();
    if (!mounted) return;
    setState(() {
      _showIntro = !hasSeenIntro;
      _checkingIntro = false;
    });
  }

  Future<void> _completeIntro() async {
    await OnboardingService.instance.markIntroSeen();
    if (!mounted) return;
    setState(() => _showIntro = false);
  }

  void _openIntro() {
    setState(() => _showIntro = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeModeService.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Personal Intelligence Engine (PIE)',
          debugShowCheckedModeBanner: false,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          themeMode: ThemeModeService.instance.themeMode,
          home: _checkingIntro
              ? const _StartupView()
              : _showIntro
              ? IntroView(onContinue: _completeIntro)
              : DashboardView(onOpenIntro: _openIntro),
        );
      },
    );
  }

  ThemeData _buildLightTheme() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF2563EB),
          secondary: const Color(0xFF059669),
          surface: Colors.white,
        );
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: Color(0xFF0F172A),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: Color(0xFF2563EB),
        unselectedItemColor: Color(0xFF64748B),
        elevation: 10,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      useMaterial3: true,
    );
  }

  ThemeData _buildDarkTheme() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF22C55E),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF3B82F6),
          secondary: const Color(0xFF22C55E),
          surface: const Color(0xFF151A24),
        );
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      primaryColor: const Color(0xFF3B82F6),
      scaffoldBackgroundColor: const Color(0xFF0B1020),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF111827),
        selectedItemColor: Color(0xFF3B82F6),
        unselectedItemColor: Color(0xFF94A3B8),
        elevation: 10,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF151A24),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      useMaterial3: true,
    );
  }
}

class _StartupView extends StatelessWidget {
  const _StartupView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}
