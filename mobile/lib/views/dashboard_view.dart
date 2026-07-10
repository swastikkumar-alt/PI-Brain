import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:file_picker/file_picker.dart';
import '../models/connector_runtime_state.dart';
import '../services/accessibility_bridge.dart';
import '../services/app_config.dart';
import '../services/database_service.dart';
import '../services/datasource_connector_registry.dart';
import '../services/local_ingestion_service.dart';
import '../services/native_contact_service.dart';
import '../services/native_datasource_service.dart';
import '../services/sync_service.dart';
import '../services/notification_service.dart';
import 'memory_view.dart';
import 'settings_view.dart';
import 'unified_agent_view.dart';

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, this.onOpenIntro});

  final VoidCallback? onOpenIntro;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  int _currentIndex = 0;
  final SyncService _syncService = SyncService();
  final LocalIngestionService _localIngestionService = LocalIngestionService();
  final NativeDatasourceService _nativeDatasourceService =
      NativeDatasourceService.instance;
  final NativeContactService _contactService = NativeContactService.instance;
  final AccessibilityBridge _accessibilityBridge = AccessibilityBridge.instance;

  int _entityCount = 0;
  String _syncStatusText = 'Online';
  List<Map<String, dynamic>> _datasourcePreferences = [];
  bool _notificationAllowed = false;
  bool _smsAllowed = false;
  bool _contactsAllowed = false;
  bool _captureServiceEnabled = false;

  final List<ConnectorRuntimeState> _connectors = datasourceConnectorDefinitions
      .map((definition) => ConnectorRuntimeState(definition: definition))
      .toList();

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    final db = await DatabaseService.instance.database;
    final entityRes = await db.rawQuery(
      'SELECT COUNT(*) as count FROM entities',
    );
    final readiness = await Future.wait<Object>([
      DatabaseService.instance.getDatasourcePreferences(),
      NotificationService.instance.checkPermission(),
      _nativeDatasourceService.checkSmsPermission(),
      _contactService.checkPermission(),
      _accessibilityBridge.isEnabled(),
    ]);

    if (!mounted) return;
    setState(() {
      _entityCount = Sqflite.firstIntValue(entityRes) ?? 0;
      _datasourcePreferences = readiness[0] as List<Map<String, dynamic>>;
      _notificationAllowed = readiness[1] as bool;
      _smsAllowed = readiness[2] as bool;
      _contactsAllowed = readiness[3] as bool;
      _captureServiceEnabled = readiness[4] as bool;
    });
  }

  Future<void> _setDatasourcePreference(String sourceId, bool isEnabled) async {
    await DatabaseService.instance.setDatasourcePreference(sourceId, isEnabled);
    await _refreshStats();
  }

  Future<bool> _ensureDatasourceEnabled(
    DatasourceConnectorDefinition connector,
  ) async {
    if (!await DatabaseService.instance.isDatasourceEnabled(
      connector.sourceId,
    )) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Turn on ${_datasourceDisplayName(connector.sourceId)} in Choose what PIE can read first.',
          ),
        ),
      );
      return false;
    }
    return true;
  }

  String _datasourceDisplayName(String sourceId) {
    for (final source in _datasourcePreferences) {
      if (source['source_id']?.toString() == sourceId) {
        return _datasourceDisplayTitle(
          sourceId,
          source['display_name']?.toString() ?? sourceId,
        );
      }
    }
    return _datasourceDisplayTitle(sourceId, sourceId);
  }

  Future<void> _runConnector(ConnectorRuntimeState connector) async {
    final definition = connector.definition;
    if (!await _ensureDatasourceEnabled(definition)) return;

    switch (definition.mode) {
      case DatasourceConnectorMode.fileImport:
        await _runLocalFileImport(connector);
      case DatasourceConnectorMode.notificationStream:
        await _connectNotificationStream(connector);
      case DatasourceConnectorMode.nativeSmsImport:
        await _importSmsMessages(connector);
      case DatasourceConnectorMode.healthConnect:
        await _connectHealthData(connector);
    }
  }

  Future<void> _runLocalFileImport(ConnectorRuntimeState connector) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
    } catch (_) {
      return;
    }

    if (result == null) {
      return;
    }

    final files = result.files
        .where((picked) => picked.path != null)
        .map((picked) => File(picked.path!))
        .toList();
    if (files.isEmpty) return;

    if (!mounted) return;
    setState(() {
      connector.status = 'SYNCING';
      _syncStatusText = 'Extracting ${files.length} PDF file(s)...';
    });

    final resultSummary = await _localIngestionService.ingestFiles(
      files,
      sourceConnector: connector.definition.sourceConnector,
    );

    if (!resultSummary.hasInsertedEntities) {
      await _refreshStats();
      if (!mounted) return;
      setState(() {
        if (resultSummary.hasOnlyDuplicates) {
          connector.status = 'SUCCESS';
          connector.lastSync = 'No Changes';
          _syncStatusText =
              'Already indexed. Skipped ${resultSummary.duplicatesSkipped} duplicate chunk(s); no sync queued.';
        } else {
          connector.status = 'FAILED';
          _syncStatusText = resultSummary.issues.isEmpty
              ? 'No new PDF text was indexed.'
              : resultSummary.issues.first.message;
        }
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _syncStatusText = 'Indexed locally. Checking backend sync...';
    });

    final cloudSynced = await _syncService.synchronize();
    await _refreshStats();

    if (!mounted) return;
    setState(() {
      connector.status = 'SUCCESS';
      connector.lastSync = 'Just Now';
      final duplicateText = resultSummary.duplicatesSkipped > 0
          ? ' Skipped ${resultSummary.duplicatesSkipped} duplicate chunk(s).'
          : '';
      _syncStatusText = cloudSynced
          ? 'Indexed ${resultSummary.entitiesInserted} new node(s) and synced.$duplicateText'
          : 'Indexed ${resultSummary.entitiesInserted} new node(s) locally; backend sync pending.$duplicateText';
    });
  }

  Future<void> _connectNotificationStream(
    ConnectorRuntimeState connector,
  ) async {
    final definition = connector.definition;
    final isSourceInstalled = switch (definition.id) {
      'gmail_notifications' =>
        await NotificationService.instance.isGmailInstalled(),
      'whatsapp_context' =>
        await NotificationService.instance.isWhatsAppInstalled(),
      _ => true,
    };

    if (!isSourceInstalled) {
      if (!mounted) return;
      setState(() {
        connector.status = 'FAILED';
        _syncStatusText = '${definition.name} source app is not installed.';
      });
      return;
    }

    final hasPermission = await NotificationService.instance.checkPermission();
    if (!hasPermission) {
      if (!mounted) return;
      setState(() {
        connector.status = 'BLOCKED';
        _syncStatusText = 'Enable PIE Notification Sync and return here.';
      });
      await NotificationService.instance.requestPermission();
      return;
    }

    if (!mounted) return;
    setState(() {
      connector.status = 'SUCCESS';
      connector.lastSync = 'Listening';
      _syncStatusText =
          '${definition.name} is connected through notification sync.';
    });
  }

  Future<void> _importSmsMessages(ConnectorRuntimeState connector) async {
    if (!mounted) return;
    setState(() {
      connector.status = 'SYNCING';
      _syncStatusText = 'Checking SMS permission...';
    });

    final result = await _nativeDatasourceService.importRecentSms();
    if (!mounted) return;

    if (result.isBlocked) {
      setState(() {
        connector.status = 'BLOCKED';
        _syncStatusText = result.blockedReason!;
      });
      return;
    }

    final cloudSynced = result.imported > 0
        ? await _syncService.synchronize()
        : false;
    await _refreshStats();
    if (!mounted) return;
    setState(() {
      connector.status = 'SUCCESS';
      connector.lastSync = result.imported > 0 ? 'Just Now' : 'No Changes';
      if (result.imported == 0 && result.skippedDuplicates > 0) {
        _syncStatusText =
            'No new SMS. Skipped ${result.skippedDuplicates} duplicate message(s); no sync queued.';
      } else {
        _syncStatusText =
            'Imported ${result.imported} SMS; skipped ${result.skippedDuplicates} duplicates. ${cloudSynced ? 'Synced.' : 'Backend sync pending.'}';
      }
    });
  }

  Future<void> _connectHealthData(ConnectorRuntimeState connector) async {
    final state = await _nativeDatasourceService.checkHealthConnect();
    if (!mounted) return;

    if (!state.available) {
      setState(() {
        connector.status = 'BLOCKED';
        _syncStatusText = state.message;
      });
      await _nativeDatasourceService.openHealthConnect();
      return;
    }

    setState(() {
      connector.status = 'BLOCKED';
      _syncStatusText =
          'Health Connect is available. Steps/sleep read permissions need the Health Connect SDK integration before importing records.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final List<Widget> tabs = [
      _buildHomeConsole(isDark),
      UnifiedAgentView(
        onOpenSettings: () {
          setState(() => _currentIndex = 3);
        },
      ),
      const MemoryView(),
      SettingsView(
        datasourcePreferences: _datasourcePreferences,
        connectors: _connectors,
        onDatasourcePreferenceChanged: _setDatasourcePreference,
        onRunConnector: _runConnector,
        onOpenGuide: widget.onOpenIntro,
      ),
    ];

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF1E1E2C), const Color(0xFF0F0F16)]
                : [const Color(0xFFF3F4F6), const Color(0xFFFFFFFF)],
          ),
        ),
        child: SafeArea(
          child: IndexedStack(index: _currentIndex, children: tabs),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_customize_outlined),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.smart_toy_outlined),
            label: 'Agent',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2_outlined),
            label: 'Cabinet',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildHomeConsole(bool isDark) {
    final readiness = <bool>[
      _entityCount > 0,
      _smsAllowed,
      _notificationAllowed,
      _contactsAllowed,
      _captureServiceEnabled,
    ];
    final readyCount = readiness.where((ready) => ready).length;

    return RefreshIndicator(
      onRefresh: _refreshStats,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildWelcomePanel(isDark),
            const SizedBox(height: 16),
            _buildHomeActionGrid(isDark),
            const SizedBox(height: 16),
            _buildLocalDataSummary(isDark),
            const SizedBox(height: 16),
            _buildSetupSummary(isDark, readyCount, readiness.length),
            const SizedBox(height: 16),
            _buildLatestStatusPanel(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomePanel(bool isDark) {
    final backendText = AppConfig.hasAzureOpenAIConfig
        ? 'AI backend configured'
        : 'Backend needed for general AI';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PIE Mobile',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Private phone intelligence for your local data and approved app actions.',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  image: const DecorationImage(
                    image: AssetImage('assets/images/logo.png'),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Ask about synced SMS, orders, spending, PDFs, and notification context. For WhatsApp or email, PIE drafts first and asks you before opening the target app.',
            style: TextStyle(
              height: 1.45,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildInfoChip(
                'Local-first data',
                Icons.lock_outline,
                const Color(0xFF059669),
                isDark,
              ),
              _buildInfoChip(
                'Approval before sending',
                Icons.fact_check_outlined,
                const Color(0xFF2563EB),
                isDark,
              ),
              _buildInfoChip(
                backendText,
                Icons.cloud_queue_outlined,
                const Color(0xFF7C3AED),
                isDark,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHomeActionGrid(bool isDark) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildActionCard(
                isDark: isDark,
                icon: Icons.chat_bubble_outline,
                title: 'Ask PIE',
                subtitle: 'Chat, voice commands and local answers.',
                accent: const Color(0xFF22C55E),
                onTap: () => setState(() => _currentIndex = 1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionCard(
                isDark: isDark,
                icon: Icons.inventory_2_outlined,
                title: 'Cabinet',
                subtitle: 'Review what PIE has stored locally.',
                accent: const Color(0xFF38BDF8),
                onTap: () => setState(() => _currentIndex = 2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildActionCard(
          isDark: isDark,
          icon: Icons.tune_outlined,
          title: 'Set up sources and permissions',
          subtitle:
              'Choose data access, import PDFs/SMS, connect notifications and change appearance.',
          accent: const Color(0xFF7C3AED),
          onTap: () => setState(() => _currentIndex = 3),
          wide: true,
        ),
      ],
    );
  }

  Widget _buildActionCard({
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required VoidCallback onTap,
    bool wide = false,
  }) {
    return Material(
      color: isDark ? const Color(0xFF151A24) : Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: wide ? 112 : 132),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLatestStatusPanel(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B202B) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.sync_alt_outlined,
              color: Color(0xFF22C55E),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Latest activity',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  _syncStatusText,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refreshStats,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupSummary(bool isDark, int readyCount, int totalCount) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Setup status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Go to Settings to control sources, permissions and appearance.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              _buildStatusPill(
                '$readyCount/$totalCount ready',
                Icons.check_circle_outline,
                readyCount == totalCount
                    ? const Color(0xFF22C55E)
                    : const Color(0xFFF59E0B),
                isDark,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMiniReadinessChip(
                _entityCount > 0,
                'Local memory',
                Icons.storage_outlined,
                isDark,
              ),
              _buildMiniReadinessChip(
                _smsAllowed,
                'SMS',
                Icons.sms_outlined,
                isDark,
              ),
              _buildMiniReadinessChip(
                _notificationAllowed,
                'Notifications',
                Icons.notifications_active_outlined,
                isDark,
              ),
              _buildMiniReadinessChip(
                _contactsAllowed,
                'Contacts',
                Icons.contacts_outlined,
                isDark,
              ),
              _buildMiniReadinessChip(
                _captureServiceEnabled,
                'Phone actions',
                Icons.accessibility_new,
                isDark,
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _currentIndex = 3),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Settings'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniReadinessChip(
    bool ready,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final color = ready ? const Color(0xFF22C55E) : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalDataSummary(bool isDark) {
    final readyCount = <bool>[
      _entityCount > 0,
      _smsAllowed,
      _notificationAllowed,
      _contactsAllowed,
      _captureServiceEnabled,
    ].where((ready) => ready).length;

    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            'Local items',
            '$_entityCount',
            Icons.hive_outlined,
            const Color(0xFF38BDF8),
            isDark,
            onTap: _showKnowledgeNodes,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            'Ready setup',
            '$readyCount/5',
            Icons.verified_outlined,
            const Color(0xFF2DD4BF),
            isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChip(String label, IconData icon, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(
    String label,
    IconData icon,
    Color color,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  String _datasourceDisplayTitle(String sourceId, String fallback) {
    return switch (sourceId) {
      'files' => 'Local Documents',
      'sms_messages' => 'SMS Messages',
      'contacts_metadata' => 'Contacts',
      'gmail_notifications' => 'Gmail Notifications',
      'whatsapp_context' => 'WhatsApp Notifications',
      'notifications' => 'Payment and App Notifications',
      'health_connect' => 'Health Connect',
      'sms_calls_future' => 'Call Logs',
      _ => fallback,
    };
  }

  Future<void> _showKnowledgeNodes() async {
    final db = await DatabaseService.instance.database;
    final res = await db.query(
      'entities',
      orderBy: 'created_at DESC',
      limit: 20,
    );

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Knowledge Nodes'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: res.isEmpty
                ? const Center(child: Text('No nodes available.'))
                : ListView.builder(
                    itemCount: res.length,
                    itemBuilder: (context, index) {
                      final entity = res[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.description,
                          color: Colors.blueAccent,
                        ),
                        title: Text(
                          entity['content']?.toString() ?? 'Empty Node',
                        ),
                        subtitle: Text(
                          'Type: ${entity['entity_type']} | Source: ${entity['source_connector']}',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDark, {
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E2C) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: color, size: 24),
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.grey,
                  size: 12,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              value,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
