import 'package:flutter/material.dart';

import '../models/connector_runtime_state.dart';
import '../models/detected_app.dart';
import '../models/phone_action.dart';
import '../services/accessibility_bridge.dart';
import '../services/app_discovery_service.dart';
import '../services/database_service.dart';
import '../services/email_connector_service.dart';
import '../services/gateway_settings_service.dart';
import '../services/native_contact_service.dart';
import '../services/native_datasource_service.dart';
import '../services/notification_service.dart';
import '../services/theme_mode_service.dart';
import '../services/voice_service.dart';
import '../services/whatsapp_connector_service.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    this.datasourcePreferences = const [],
    this.connectors = const [],
    this.onDatasourcePreferenceChanged,
    this.onRunConnector,
    this.onOpenGuide,
  });

  final List<Map<String, dynamic>> datasourcePreferences;
  final List<ConnectorRuntimeState> connectors;
  final Future<void> Function(String sourceId, bool enabled)?
  onDatasourcePreferenceChanged;
  final Future<void> Function(ConnectorRuntimeState connector)? onRunConnector;
  final VoidCallback? onOpenGuide;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _voice = VoiceService.instance;
  final _contacts = NativeContactService.instance;
  final _accessibility = AccessibilityBridge.instance;
  final _notifications = NotificationService.instance;
  final _nativeSources = NativeDatasourceService.instance;
  final _whatsApp = WhatsAppConnectorService.instance;
  final _email = EmailConnectorService.instance;
  final _db = DatabaseService.instance;
  final _themeModeService = ThemeModeService.instance;
  final _appDiscovery = AppDiscoveryService.instance;
  final _gatewaySettings = GatewaySettingsService.instance;

  bool _loading = true;
  bool _micAllowed = false;
  bool _contactsAllowed = false;
  bool _accessibilityEnabled = false;
  bool _notificationAllowed = false;
  bool _smsAllowed = false;
  bool _whatsAppAvailable = false;
  bool _emailAvailable = false;
  List<DetectedApp> _detectedApps = const [];
  GatewayRuntimeSettings _backendSettings = const GatewayRuntimeSettings(
    gatewayUrl: '',
    hasCustomUrl: false,
    hasBearerToken: false,
  );
  AppUnlockPolicy _unlockPolicy = AppUnlockPolicy.unlockEachTime;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object>([
      _voice.checkPermission(),
      _contacts.checkPermission(),
      _accessibility.isEnabled(),
      _notifications.checkPermission(),
      _nativeSources.checkSmsPermission(),
      _whatsApp.isAvailable(),
      _email.isAvailable(),
      _db.getAppUnlockPolicy(),
      _appDiscovery.listSupportedApps(),
      _gatewaySettings.currentSettings(),
    ]);

    if (!mounted) return;
    setState(() {
      _micAllowed = results[0] as bool;
      _contactsAllowed = results[1] as bool;
      _accessibilityEnabled = results[2] as bool;
      _notificationAllowed = results[3] as bool;
      _smsAllowed = results[4] as bool;
      _whatsAppAvailable = results[5] as bool;
      _emailAvailable = results[6] as bool;
      _unlockPolicy = results[7] as AppUnlockPolicy;
      _detectedApps = results[8] as List<DetectedApp>;
      _backendSettings = results[9] as GatewayRuntimeSettings;
      _loading = false;
    });
  }

  Future<void> _runAndRefresh(Future<void> Function() action) async {
    await action();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await _refresh();
  }

  Future<void> _setUnlockPolicy(AppUnlockPolicy policy) async {
    await _db.setAppUnlockPolicy(policy);
    if (!mounted) return;
    setState(() => _unlockPolicy = policy);
  }

  String _unlockPolicyLabel(AppUnlockPolicy policy) {
    return switch (policy) {
      AppUnlockPolicy.unlockEachTime => 'Ask each time',
      AppUnlockPolicy.sessionUnlock => 'Resume after unlock',
      AppUnlockPolicy.skipLockedApps => 'Skip locked apps',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader(title: 'Experience'),
          _AppearanceTile(themeModeService: _themeModeService),
          _SettingTile(
            icon: Icons.info_outline,
            title: 'What PIE can do',
            subtitle: 'Open the intro guide for new users',
            ready: true,
            actionLabel: 'View',
            onPressed: widget.onOpenGuide == null
                ? null
                : () async => widget.onOpenGuide!(),
          ),
          _BackendSettingsTile(
            settings: _backendSettings,
            onConfigure: _showBackendSettingsDialog,
          ),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Command Permissions'),
          _SettingTile(
            icon: Icons.mic_none,
            title: 'Microphone',
            subtitle: 'Push-to-talk voice commands',
            ready: _micAllowed,
            actionLabel: _micAllowed ? 'Allowed' : 'Allow',
            onPressed: _micAllowed
                ? null
                : () => _runAndRefresh(_voice.requestPermission),
          ),
          _SettingTile(
            icon: Icons.contacts_outlined,
            title: 'Contacts',
            subtitle: 'Recipient lookup and alias learning',
            ready: _contactsAllowed,
            actionLabel: _contactsAllowed ? 'Allowed' : 'Allow',
            onPressed: _contactsAllowed
                ? null
                : () => _runAndRefresh(_contacts.requestPermission),
          ),
          _SettingTile(
            icon: Icons.accessibility_new,
            title: 'Capture Service',
            subtitle: 'Verified WhatsApp send automation',
            ready: _accessibilityEnabled,
            actionLabel: _accessibilityEnabled ? 'Enabled' : 'Enable',
            onPressed: _accessibilityEnabled
                ? null
                : () => _runAndRefresh(_accessibility.openSettings),
          ),
          _SettingTile(
            icon: Icons.notifications_active_outlined,
            title: 'Notification Sync',
            subtitle: 'Gmail and WhatsApp context ingestion',
            ready: _notificationAllowed,
            actionLabel: _notificationAllowed ? 'Enabled' : 'Enable',
            onPressed: _notificationAllowed
                ? null
                : () => _runAndRefresh(_notifications.requestPermission),
          ),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Data Access'),
          _DataSourcePreferencesPanel(
            sources: widget.datasourcePreferences,
            onChanged: widget.onDatasourcePreferenceChanged,
          ),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Imports and Context'),
          _ConnectorActionsPanel(
            sources: widget.datasourcePreferences,
            connectors: widget.connectors,
            onRunConnector: widget.onRunConnector,
          ),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Connectors'),
          _SettingTile(
            icon: Icons.chat_outlined,
            title: 'WhatsApp',
            subtitle: 'Regular or Business installation',
            ready: _whatsAppAvailable,
            actionLabel: _whatsAppAvailable ? 'Available' : 'Missing',
          ),
          _SettingTile(
            icon: Icons.email_outlined,
            title: 'Email',
            subtitle: 'Compose flow availability',
            ready: _emailAvailable,
            actionLabel: _emailAvailable ? 'Available' : 'Missing',
          ),
          _SettingTile(
            icon: Icons.sms_outlined,
            title: 'SMS',
            subtitle: 'Local SMS import',
            ready: _smsAllowed,
            actionLabel: _smsAllowed ? 'Allowed' : 'Allow',
            onPressed: _smsAllowed
                ? null
                : () => _runAndRefresh(_nativeSources.requestSmsPermission),
          ),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Detected Apps'),
          _DetectedAppsPanel(apps: _detectedApps),
          const SizedBox(height: 18),
          _SectionHeader(title: 'Locked Apps'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: DropdownButtonFormField<AppUnlockPolicy>(
              key: ValueKey(_unlockPolicy),
              initialValue: _unlockPolicy,
              decoration: const InputDecoration(
                labelText: 'WhatsApp app-lock handling',
                border: OutlineInputBorder(),
              ),
              items: AppUnlockPolicy.values
                  .map(
                    (policy) => DropdownMenuItem(
                      value: policy,
                      child: Text(_unlockPolicyLabel(policy)),
                    ),
                  )
                  .toList(),
              onChanged: (policy) {
                if (policy != null) _setUnlockPolicy(policy);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showBackendSettingsDialog() async {
    final result = await showDialog<_BackendSettingsDialogResult>(
      context: context,
      builder: (context) => _BackendSettingsDialog(
        initialGatewayUrl: _backendSettings.gatewayUrl,
        hasBearerToken: _backendSettings.hasBearerToken,
      ),
    );

    if (!mounted || result == null) return;

    // Let the dialog route and focused text fields fully deactivate before
    // writing secure storage and refreshing the Settings tree.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (result.reset) {
      await _gatewaySettings.clear();
    } else {
      await _gatewaySettings.save(
        gatewayUrl: result.gatewayUrl,
        bearerToken: result.bearerToken,
      );
    }
    if (mounted) await _refresh();
  }
}

class _BackendSettingsDialogResult {
  const _BackendSettingsDialogResult._({
    required this.reset,
    required this.gatewayUrl,
    required this.bearerToken,
  });

  const _BackendSettingsDialogResult.reset()
    : this._(reset: true, gatewayUrl: '', bearerToken: null);

  const _BackendSettingsDialogResult.save({
    required String gatewayUrl,
    required String bearerToken,
  }) : this._(reset: false, gatewayUrl: gatewayUrl, bearerToken: bearerToken);

  final bool reset;
  final String gatewayUrl;
  final String? bearerToken;
}

class _BackendSettingsDialog extends StatefulWidget {
  const _BackendSettingsDialog({
    required this.initialGatewayUrl,
    required this.hasBearerToken,
  });

  final String initialGatewayUrl;
  final bool hasBearerToken;

  @override
  State<_BackendSettingsDialog> createState() => _BackendSettingsDialogState();
}

class _BackendSettingsDialogState extends State<_BackendSettingsDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialGatewayUrl);
    _tokenController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI Backend'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Gateway URL',
                hintText: 'https://pie-llm-gateway.example.workers.dev/api/v1',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Bearer token',
                hintText: widget.hasBearerToken
                    ? 'Leave blank to keep current token'
                    : 'Optional',
              ),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context, const _BackendSettingsDialogResult.reset());
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(
              context,
              _BackendSettingsDialogResult.save(
                gatewayUrl: _urlController.text,
                bearerToken: _tokenController.text,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DetectedAppsPanel extends StatelessWidget {
  const _DetectedAppsPanel({required this.apps});

  final List<DetectedApp> apps;

  @override
  Widget build(BuildContext context) {
    final installed = apps.where((app) => app.installed).toList();
    final visible = installed.isEmpty ? apps.take(4).toList() : installed;
    if (visible.isEmpty) {
      return const Card(
        elevation: 0,
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('App discovery is unavailable on this device.'),
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: List.generate(visible.length, (index) {
          final app = visible[index];
          return Column(
            children: [
              ListTile(
                leading: Icon(
                  app.icon,
                  color: app.installed ? Colors.greenAccent : Colors.grey,
                ),
                title: Text(
                  app.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(app.capability),
                trailing: _SmallPill(
                  label: app.status,
                  color: app.installed
                      ? const Color(0xFF22C55E)
                      : const Color(0xFF94A3B8),
                  icon: app.installed
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                ),
              ),
              if (index < visible.length - 1)
                Divider(
                  height: 1,
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.12),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ready,
    required this.actionLabel,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool ready;
  final String actionLabel;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = ready ? Colors.greenAccent : Colors.orangeAccent;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: OutlinedButton(
          onPressed: onPressed == null ? null : () => onPressed!(),
          child: Text(actionLabel),
        ),
      ),
    );
  }
}

class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile({required this.themeModeService});

  final ThemeModeService themeModeService;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeModeService,
      builder: (context, _) {
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.contrast_outlined),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Appearance',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.settings_suggest_outlined),
                    ),
                  ],
                  selected: {themeModeService.themeMode},
                  onSelectionChanged: (selection) {
                    themeModeService.setThemeMode(selection.first);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BackendSettingsTile extends StatelessWidget {
  const _BackendSettingsTile({
    required this.settings,
    required this.onConfigure,
  });

  final GatewayRuntimeSettings settings;
  final Future<void> Function() onConfigure;

  @override
  Widget build(BuildContext context) {
    final ready =
        settings.gatewayUrl.startsWith('https://') ||
        settings.gatewayUrl.startsWith('http://');
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        leading: Icon(
          Icons.cloud_queue_outlined,
          color: ready ? Colors.greenAccent : Colors.orangeAccent,
        ),
        title: const Text(
          'AI Backend',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          settings.hasCustomUrl
              ? settings.gatewayUrl
              : 'Default: ${settings.gatewayUrl}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: OutlinedButton(
          onPressed: onConfigure,
          child: Text(settings.hasCustomUrl ? 'Edit' : 'Set'),
        ),
      ),
    );
  }
}

class _DataSourcePreferencesPanel extends StatelessWidget {
  const _DataSourcePreferencesPanel({
    required this.sources,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> sources;
  final Future<void> Function(String sourceId, bool enabled)? onChanged;

  @override
  Widget build(BuildContext context) {
    final ordered = _orderedSources(sources)
        .where(
          (source) => _showSourceInSettings(source['source_id']?.toString()),
        )
        .toList();
    if (ordered.isEmpty) {
      return const Card(
        elevation: 0,
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('Source choices are loading.'),
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: List.generate(ordered.length, (index) {
          final source = ordered[index];
          final sourceId = source['source_id']?.toString() ?? '';
          final enabled = source['is_enabled'] == 1;
          return Column(
            children: [
              SwitchListTile(
                value: enabled,
                secondary: Icon(_sourceIcon(sourceId)),
                title: Text(
                  _sourceTitle(sourceId, source['display_name']?.toString()),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(_sourceSubtitle(sourceId, enabled)),
                onChanged: sourceId.isEmpty || onChanged == null
                    ? null
                    : (value) => onChanged!(sourceId, value),
              ),
              if (index < ordered.length - 1)
                Divider(
                  height: 1,
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.12),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _ConnectorActionsPanel extends StatelessWidget {
  const _ConnectorActionsPanel({
    required this.sources,
    required this.connectors,
    required this.onRunConnector,
  });

  final List<Map<String, dynamic>> sources;
  final List<ConnectorRuntimeState> connectors;
  final Future<void> Function(ConnectorRuntimeState connector)? onRunConnector;

  @override
  Widget build(BuildContext context) {
    final visible = connectors
        .where((connector) => connector.definition.id != 'health_connect')
        .toList();
    if (visible.isEmpty) {
      return const Card(
        elevation: 0,
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('Connector actions are loading.'),
        ),
      );
    }

    return Column(
      children: visible
          .map(
            (connector) => _ConnectorActionCard(
              connector: connector,
              enabled: _isSourceEnabled(sources, connector.definition.sourceId),
              onRunConnector: onRunConnector,
            ),
          )
          .toList(),
    );
  }
}

class _ConnectorActionCard extends StatelessWidget {
  const _ConnectorActionCard({
    required this.connector,
    required this.enabled,
    required this.onRunConnector,
  });

  final ConnectorRuntimeState connector;
  final bool enabled;
  final Future<void> Function(ConnectorRuntimeState connector)? onRunConnector;

  @override
  Widget build(BuildContext context) {
    final definition = connector.definition;
    final accent = _connectorAccent(definition.id);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_connectorIcon(definition.id), color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    definition.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    definition.description,
                    style: const TextStyle(color: Colors.grey, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SmallPill(
                        label: enabled ? 'Source on' : 'Source off',
                        color: enabled
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFF59E0B),
                        icon: enabled
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                      ),
                      _SmallPill(
                        label: connector.statusLabel,
                        color: _statusColor(connector.status),
                        icon: Icons.info_outline,
                      ),
                      Text(
                        'Last: ${connector.lastSync}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: connector.status == 'SYNCING'
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton.tonal(
                            onPressed: enabled && onRunConnector != null
                                ? () => onRunConnector!(connector)
                                : null,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(120, 44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              enabled
                                  ? definition.actionLabel
                                  : 'Turn on first',
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
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
}

List<Map<String, dynamic>> _orderedSources(List<Map<String, dynamic>> sources) {
  final ordered = List<Map<String, dynamic>>.from(sources);
  ordered.sort((a, b) {
    final left = _sourceSortOrder(a['source_id']?.toString() ?? '');
    final right = _sourceSortOrder(b['source_id']?.toString() ?? '');
    if (left != right) return left.compareTo(right);
    return (a['display_name']?.toString() ?? '').compareTo(
      b['display_name']?.toString() ?? '',
    );
  });
  return ordered;
}

bool _isSourceEnabled(List<Map<String, dynamic>> sources, String sourceId) {
  return sources.any(
    (source) =>
        source['source_id']?.toString() == sourceId &&
        source['is_enabled'] == 1,
  );
}

bool _showSourceInSettings(String? sourceId) {
  return sourceId != 'health_connect' && sourceId != 'sms_calls_future';
}

int _sourceSortOrder(String sourceId) {
  return switch (sourceId) {
    'files' => 0,
    'sms_messages' => 1,
    'contacts_metadata' => 2,
    'gmail_notifications' => 3,
    'whatsapp_context' => 4,
    'notifications' => 5,
    'health_connect' => 90,
    'sms_calls_future' => 91,
    _ => 80,
  };
}

String _sourceTitle(String sourceId, String? fallback) {
  return switch (sourceId) {
    'files' => 'Local Documents',
    'sms_messages' => 'SMS Messages',
    'contacts_metadata' => 'Contacts',
    'gmail_notifications' => 'Gmail Notifications',
    'whatsapp_context' => 'WhatsApp Notifications',
    'notifications' => 'Payment and App Notifications',
    'health_connect' => 'Health Connect',
    'sms_calls_future' => 'Call Logs',
    _ => fallback ?? sourceId,
  };
}

String _sourceSubtitle(String sourceId, bool enabled) {
  final purpose = switch (sourceId) {
    'files' => 'PDF and document text stored locally',
    'sms_messages' => 'SMS data for spend, order and spam questions',
    'contacts_metadata' => 'Contact names, phones and aliases',
    'gmail_notifications' => 'Gmail notification summaries',
    'whatsapp_context' => 'WhatsApp notification context',
    'notifications' => 'Payment and app notifications',
    'health_connect' => 'Optional supported health records',
    'sms_calls_future' => 'Future call-log spam review',
    _ => 'Local source',
  };
  return enabled ? '$purpose. PIE can use it.' : '$purpose. Off for now.';
}

IconData _sourceIcon(String sourceId) {
  return switch (sourceId) {
    'files' => Icons.folder_copy_outlined,
    'sms_messages' => Icons.sms_outlined,
    'contacts_metadata' => Icons.contacts_outlined,
    'gmail_notifications' => Icons.mail_outline,
    'whatsapp_context' => Icons.chat_outlined,
    'notifications' => Icons.notifications_active_outlined,
    'health_connect' => Icons.health_and_safety_outlined,
    'sms_calls_future' => Icons.call_outlined,
    _ => Icons.data_object_outlined,
  };
}

IconData _connectorIcon(String connectorId) {
  return switch (connectorId) {
    'local_pdf_scanner' => Icons.picture_as_pdf_outlined,
    'gmail_notifications' => Icons.mail_outline,
    'sms_messages' => Icons.sms_outlined,
    'whatsapp_context' => Icons.chat_outlined,
    _ => Icons.link_outlined,
  };
}

Color _connectorAccent(String connectorId) {
  return switch (connectorId) {
    'local_pdf_scanner' => const Color(0xFFEF4444),
    'gmail_notifications' => const Color(0xFF2563EB),
    'sms_messages' => const Color(0xFF22C55E),
    'whatsapp_context' => const Color(0xFF16A34A),
    _ => const Color(0xFF38BDF8),
  };
}

Color _statusColor(String status) {
  return switch (status) {
    'SUCCESS' => const Color(0xFF22C55E),
    'FAILED' => const Color(0xFFEF4444),
    'BLOCKED' => const Color(0xFFF59E0B),
    'SYNCING' => const Color(0xFF38BDF8),
    _ => const Color(0xFF94A3B8),
  };
}
