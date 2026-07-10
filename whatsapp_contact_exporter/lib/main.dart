import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models/export_models.dart';
import 'services/export_formatter.dart';
import 'services/exporter_database.dart';
import 'services/manual_import_parser.dart';
import 'services/native_bridge.dart';
import 'services/phone_normalizer.dart';
import 'services/web_whatsapp_extractor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ExtractorApp());
}

class ExtractorApp extends StatelessWidget {
  const ExtractorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WA Group Extractor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0f766e)),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: const ExtractorHomePage(),
    );
  }
}

class ExtractorHomePage extends StatefulWidget {
  const ExtractorHomePage({
    super.key,
    this.database,
    this.bridge,
    this.enableWebView = true,
  });

  final ExporterDatabase? database;
  final NativeBridge? bridge;
  final bool enableWebView;

  @override
  State<ExtractorHomePage> createState() => _ExtractorHomePageState();
}

enum _ExtractorSource { phone, web }

class _ExtractorHomePageState extends State<ExtractorHomePage> {
  late final ExporterDatabase _database;
  late final NativeBridge _bridge;
  final _parser = ManualImportParser();
  final _uuid = const Uuid();
  final _searchController = TextEditingController();

  late final WebViewController _webController;
  Completer<String>? _webScanCompleter;

  ExporterCounts _counts = const ExporterCounts(
    contacts: 0,
    groups: 0,
    groupMembers: 0,
    exports: 0,
  );
  List<ExportRecord> _exports = const [];
  List<ExtractionRun> _runs = const [];
  List<WebWhatsAppGroupCandidate> _webGroups = const [];
  Set<String> _selectedGroupIds = {};
  MemberRoleFilter _roleFilter = MemberRoleFilter.all;
  bool _includeRoleColumns = true;
  bool _dedupeExports = false;
  bool _busy = true;
  bool _webLoading = true;
  bool _webScanAttempted = false;
  bool _accessibilityEnabled = false;
  _ExtractorSource _selectedSource = _ExtractorSource.phone;
  String _status = 'Starting extractor';
  String _webStatus = 'Loading WhatsApp Web';

  @override
  void initState() {
    super.initState();
    _database = widget.database ?? ExporterDatabase();
    _bridge = widget.bridge ?? NativeBridge();
    if (widget.enableWebView) {
      _initWebView();
    } else {
      _webLoading = false;
      _webStatus = 'WhatsApp Web login required for advanced bulk scan.';
    }
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(WebWhatsAppExtractor.desktopUserAgent)
      ..enableZoom(true)
      ..addJavaScriptChannel(
        'WaGroupExtractorBridge',
        onMessageReceived: (message) {
          final completer = _webScanCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete(message.message);
          }
          _webScanCompleter = null;
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _webLoading = true;
                _webStatus = 'Loading WhatsApp Web';
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() {
                _webLoading = false;
                _webStatus =
                    'Open Linked Devices on WhatsApp and connect this Web session if needed.';
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) {
              return;
            }
            if (mounted) {
              setState(() {
                _webLoading = false;
                _webStatus = 'WebView load error: ${error.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://web.whatsapp.com/'));
  }

  Future<void> _reloadWhatsAppWeb() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _run('Repairing WhatsApp Web session', () async {
      setState(() {
        _webLoading = true;
        _webStatus = 'Checking WhatsApp Web network';
      });
      final check = await _bridge.checkWhatsAppWeb();
      if (!check.reachable) {
        setState(() {
          _webLoading = false;
          _webStatus = check.summary;
        });
        throw StateError(check.summary);
      }
      setState(() {
        _webStatus = '${check.summary} Reloading embedded session.';
      });
      await _webController.clearCache();
      await _webController.loadRequest(Uri.parse('https://web.whatsapp.com/'));
    });
  }

  Future<void> _openFullScreenWebLogin() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const _FullScreenWebLoginPage(),
      ),
    );
    if (!mounted) {
      return;
    }
    await _reloadWhatsAppWeb();
  }

  Future<void> _refresh() async {
    try {
      final counts = await _database.counts();
      final exports = await _database.exports();
      final runs = await _database.extractionRuns();
      final accessibilityEnabled = await _bridge.accessibilityEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _counts = counts;
        _exports = exports.take(5).toList();
        _runs = runs.take(5).toList();
        _accessibilityEnabled = accessibilityEnabled;
        _busy = false;
        _status = 'Ready';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _status = 'Startup blocked: $error';
      });
    }
  }

  Future<T?> _run<T>(String label, Future<T> Function() action) async {
    if (_busy) {
      return null;
    }
    setState(() {
      _busy = true;
      _status = label;
    });
    try {
      final result = await action();
      await _refresh();
      return result;
    } catch (error) {
      if (!mounted) {
        return null;
      }
      final message = _friendlyError(error);
      setState(() {
        _busy = false;
        _status = 'Failed: $message';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $message')));
      return null;
    }
  }

  String _friendlyError(Object error) {
    final message = '$error';
    const statePrefix = 'Bad state: ';
    if (message.startsWith(statePrefix)) {
      return message.substring(statePrefix.length);
    }
    return message;
  }

  Future<void> _scanWhatsAppWeb() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _run('Scanning WhatsApp Web groups', () async {
      setState(() => _webScanAttempted = true);
      if (_webStatus.startsWith('WebView load error:')) {
        final check = await _bridge.checkWhatsAppWeb();
        if (check.reachable) {
          setState(() {
            _webLoading = true;
            _webStatus = '${check.summary} Reloading embedded session.';
          });
          await _webController.clearCache();
          await _webController.loadRequest(
            Uri.parse('https://web.whatsapp.com/'),
          );
          throw StateError(
            'WhatsApp Web was reloaded after a WebView error. Wait for it to finish loading, then scan again.',
          );
        }
        setState(() => _webStatus = check.summary);
        throw StateError('WhatsApp Web did not load. ${check.summary}');
      }
      final scan = await _readWhatsAppWebScan();
      if (scan.loginRequired) {
        setState(() {
          _webStatus =
              'WhatsApp Web is showing the login screen. Link it in full-screen login, or use Phone capture.';
        });
        throw StateError('WhatsApp Web is not connected yet.');
      }
      if (scan.error.isNotEmpty && scan.groups.isEmpty) {
        setState(() => _webStatus = scan.error);
        throw StateError(scan.error);
      }
      if (!scan.ready && scan.groups.isEmpty) {
        setState(() {
          _webStatus =
              'WhatsApp Web is not ready. Wait for chats to load, open a group, or use Phone capture.';
        });
        throw StateError('WhatsApp Web is not ready yet.');
      }
      setState(() {
        _webGroups = scan.groups;
        _selectedGroupIds = WebGroupSelection.selectAll(scan.groups);
        _webStatus = scan.groups.isEmpty
            ? 'WhatsApp Web is linked, but no group metadata was readable. Open a group chat or group info in Web, then scan again.'
            : 'Found ${scan.groups.length} groups. Select all or choose custom groups.';
      });
    });
  }

  Future<WebWhatsAppScanResult> _readWhatsAppWebScan() async {
    final quick = await _runWhatsAppWebQuickScanScript();
    var latest = WebWhatsAppScanResult.fromRawJavaScriptResult(quick);
    if (latest.loginRequired || latest.groups.isNotEmpty || !latest.ready) {
      return latest;
    }

    for (var attempt = 0; attempt < 1; attempt += 1) {
      final raw = await _runWhatsAppWebScanScript();
      latest = WebWhatsAppScanResult.fromRawJavaScriptResult(raw);
      final retryableNoResult = latest.error.contains(
        'scan returned no readable data',
      );
      if (latest.error.contains('scan timed out')) {
        return WebWhatsAppScanResult(
          ready: true,
          loginRequired: false,
          groups: const [],
          error:
              'Deep WhatsApp Web scan timed out. Open the Groups filter or a group info screen, then scan again.',
          source: 'whatsapp_web',
        );
      }
      if (latest.loginRequired ||
          latest.ready ||
          latest.groups.isNotEmpty ||
          (latest.error.isNotEmpty && !retryableNoResult)) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    return latest;
  }

  Future<Object> _runWhatsAppWebQuickScanScript() {
    return _webController
        .runJavaScriptReturningResult(WebWhatsAppExtractor.quickScanScript)
        .timeout(
          const Duration(seconds: 4),
          onTimeout: () => jsonEncode({
            'ready': false,
            'loginRequired': false,
            'groups': const [],
            'error': 'Fast WhatsApp Web scan timed out.',
            'source': 'whatsapp_web_dom',
          }),
        );
  }

  Future<String> _runWhatsAppWebScanScript() async {
    final previous = _webScanCompleter;
    if (previous != null && !previous.isCompleted) {
      previous.complete('{"error":"Previous WhatsApp Web scan was replaced."}');
    }
    final completer = Completer<String>();
    _webScanCompleter = completer;
    unawaited(
      _webController.runJavaScript(WebWhatsAppExtractor.scanScript).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        if (_webScanCompleter == completer && !completer.isCompleted) {
          completer.complete(
            jsonEncode({
              'ready': false,
              'loginRequired': false,
              'groups': const [],
              'error': 'WhatsApp Web script injection failed: $error',
              'source': 'whatsapp_web',
            }),
          );
          _webScanCompleter = null;
        }
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (_webScanCompleter == completer) {
          _webScanCompleter = null;
        }
        return '{"error":"WhatsApp Web scan timed out before returning data."}';
      },
    );
  }

  Future<void> _saveSelectedWebGroups() async {
    await _run('Saving selected WhatsApp Web groups', () async {
      final selected = WebGroupSelection.selectedGroups(
        _webGroups,
        _selectedGroupIds,
      );
      if (selected.isEmpty) {
        throw StateError('Select at least one group first.');
      }
      final now = DateTime.now();
      final runId = _uuid.v4();
      final groups = <WhatsAppGroup>[];
      final members = <GroupMember>[];
      var memberCount = 0;

      for (final webGroup in selected) {
        final localGroupId = _uuid.v4();
        groups.add(
          WhatsAppGroup(
            id: localGroupId,
            name: webGroup.name.isEmpty ? webGroup.whatsappId : webGroup.name,
            capturedAt: now,
            sourceAccountLabel: 'whatsapp_web',
            whatsappId: webGroup.whatsappId,
            extractionRunId: runId,
          ),
        );
        for (final webMember in webGroup.members) {
          final hasPhone = webMember.normalizedPhone.isNotEmpty;
          final role = webMember.isAdmin
              ? ContactRole.admin
              : ContactRole.member;
          members.add(
            GroupMember(
              id: _uuid.v4(),
              groupId: localGroupId,
              displayName: webMember.displayName.isEmpty
                  ? webMember.whatsappId
                  : webMember.displayName,
              phone: webMember.phone,
              normalizedPhone: webMember.normalizedPhone,
              role: role,
              confidence: hasPhone ? 'high' : 'low',
              source: 'whatsapp_web',
              whatsappId: webMember.whatsappId,
              phoneVisibility: hasPhone
                  ? PhoneVisibility.visible
                  : PhoneVisibility.notVisible,
              isAdmin: webMember.isAdmin,
              extractionRunId: runId,
            ),
          );
          memberCount += 1;
        }
      }

      final run = ExtractionRun(
        id: runId,
        source: 'whatsapp_web',
        status: ExtractionRunStatus.completed,
        startedAt: now,
        finishedAt: DateTime.now(),
        selectedGroupCount: groups.length,
        memberCount: memberCount,
        error: '',
      );
      await _database.insertExtractionRunWithGroups(
        run: run,
        groups: groups,
        members: members,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Saved ${groups.length} groups and $memberCount members',
            ),
          ),
        );
      }
    });
  }

  Future<void> _importLocalContacts() async {
    await _run('Importing phone contacts', () async {
      var allowed = await _bridge.contactsPermissionGranted();
      if (!allowed) {
        allowed = await _bridge.requestContactsPermission();
      }
      if (!allowed) {
        throw StateError('Contacts permission was denied.');
      }
      final contacts = await _bridge.importLocalContacts();
      await _database.upsertContacts(contacts);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported ${contacts.length} phone contacts')),
        );
      }
    });
  }

  Future<void> _manualImport() async {
    await _run('Opening paste/import parser', () async {
      final input = await showDialog<String>(
        context: context,
        builder: (context) => const _ManualImportDialog(),
      );
      if (input == null || input.trim().isEmpty) {
        return;
      }
      final contacts = _parser.parseContacts(input);
      if (contacts.isEmpty) {
        throw StateError('No contacts were detected in the pasted data.');
      }
      await _database.upsertContacts(contacts);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported ${contacts.length} pasted contacts'),
          ),
        );
      }
    });
  }

  Future<void> _openWhatsApp() async {
    await _run('Opening WhatsApp', () => _bridge.openWhatsApp());
  }

  Future<void> _loadLatestWhatsAppCapture() async {
    await _run('Loading visible WhatsApp group batch', () async {
      final enabled = await _bridge.accessibilityEnabled();
      if (!enabled) {
        throw StateError('Enable the capture service first.');
      }
      final capture = await _bridge.latestCapture();
      if (capture == null || capture.members.isEmpty) {
        throw StateError(
          'No visible group batch found. Open WhatsApp group info and scroll the members you want first.',
        );
      }
      if (!mounted) {
        return;
      }
      final reviewed = await showModalBottomSheet<_ReviewedCapture>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => _CaptureReviewSheet(batch: capture),
      );
      if (reviewed == null || reviewed.members.isEmpty) {
        return;
      }

      final now = DateTime.now();
      final runId = _uuid.v4();
      final group = WhatsAppGroup(
        id: _uuid.v4(),
        name: reviewed.groupName,
        capturedAt: now,
        sourceAccountLabel: reviewed.sourceAccountLabel,
        extractionRunId: runId,
      );
      final members = reviewed.members
          .map(
            (member) => GroupMember(
              id: _uuid.v4(),
              groupId: group.id,
              displayName: member.displayName,
              phone: member.phone,
              normalizedPhone: PhoneNormalizer.normalize(member.phone),
              role: member.role,
              confidence: member.confidence,
              source: member.source,
              whatsappId: member.whatsappId,
              phoneVisibility: member.phone.isEmpty
                  ? PhoneVisibility.notVisible
                  : PhoneVisibility.visible,
              isAdmin: member.role == ContactRole.admin,
              extractionRunId: runId,
            ),
          )
          .toList();
      final run = ExtractionRun(
        id: runId,
        source: 'android_accessibility',
        status: ExtractionRunStatus.completed,
        startedAt: now,
        finishedAt: DateTime.now(),
        selectedGroupCount: 1,
        memberCount: members.length,
        error: '',
      );
      await _database.insertExtractionRunWithGroups(
        run: run,
        groups: [group],
        members: members,
      );
      await _bridge.clearLatestCapture();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${members.length} reviewed members')),
        );
      }
    });
  }

  Future<void> _exportCsv({
    required String exportType,
    required String filePrefix,
    required MemberRoleFilter roleFilter,
    required bool dedupe,
  }) async {
    await _run('Exporting $exportType', () async {
      final contacts = await _database.contacts();
      final groups = await _database.groups();
      final members = await _database.groupMembers();
      final content = ExportFormatter.contactsCsv(
        contacts: contacts,
        groups: groups,
        members: members,
        roleFilter: roleFilter,
        dedupe: dedupe,
        includeRoleColumns: _includeRoleColumns,
      );
      final rowCount = content.split('\n').length - 1;
      return _writeTextExport(
        content: content,
        exportType: exportType,
        fileName: '${filePrefix}_${_timestamp()}.csv',
        mimeType: 'text/csv',
        rowCount: rowCount,
      );
    });
  }

  Future<void> _exportXlsx() async {
    await _run('Exporting XLSX', () async {
      final contacts = await _database.contacts();
      final groups = await _database.groups();
      final members = await _database.groupMembers();
      final bytes = ExportFormatter.xlsxBytes(
        contacts: contacts,
        groups: groups,
        members: members,
        roleFilter: _roleFilter,
        dedupe: _dedupeExports,
        includeRoleColumns: _includeRoleColumns,
      );
      return _writeBytesExport(
        bytes: bytes,
        exportType: 'xlsx',
        fileName: 'wa_group_contacts_${_timestamp()}.xlsx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        rowCount: _counts.contacts + _counts.groupMembers,
      );
    });
  }

  Future<void> _exportVcard() async {
    await _run('Exporting vCard', () async {
      final contacts = await _database.contacts();
      final members = await _database.groupMembers();
      final content = ExportFormatter.vcard(
        contacts: contacts,
        members: members,
        roleFilter: _roleFilter,
      );
      final rowCount = RegExp('BEGIN:VCARD').allMatches(content).length;
      return _writeTextExport(
        content: content,
        exportType: 'vcard',
        fileName: 'wa_group_contacts_${_timestamp()}.vcf',
        mimeType: 'text/vcard',
        rowCount: rowCount,
      );
    });
  }

  Future<void> _exportJson() async {
    await _run('Exporting JSON', _createJsonExport);
  }

  Future<_ExportedFile> _createJsonExport() async {
    final contacts = await _database.contacts();
    final groups = await _database.groups();
    final members = await _database.groupMembers();
    final runs = await _database.extractionRuns();
    final content = ExportFormatter.exportJson(
      contacts: contacts,
      groups: groups,
      members: members,
      extractionRuns: runs,
    );
    return _writeTextExport(
      content: content,
      exportType: 'json',
      fileName: 'wa_group_contacts_${_timestamp()}.json',
      mimeType: 'application/json',
      rowCount: contacts.length + groups.length + members.length,
    );
  }

  Future<_ExportedFile> _writeTextExport({
    required String content,
    required String exportType,
    required String fileName,
    required String mimeType,
    required int rowCount,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, fileName));
    await file.writeAsString(content, flush: true);
    return _copyAndRecordExport(
      localPath: file.path,
      exportType: exportType,
      fileName: fileName,
      mimeType: mimeType,
      rowCount: rowCount,
    );
  }

  Future<_ExportedFile> _writeBytesExport({
    required List<int> bytes,
    required String exportType,
    required String fileName,
    required String mimeType,
    required int rowCount,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return _copyAndRecordExport(
      localPath: file.path,
      exportType: exportType,
      fileName: fileName,
      mimeType: mimeType,
      rowCount: rowCount,
    );
  }

  Future<_ExportedFile> _copyAndRecordExport({
    required String localPath,
    required String exportType,
    required String fileName,
    required String mimeType,
    required int rowCount,
  }) async {
    final downloadsPath = await _bridge.copyToDownloads(
      sourcePath: localPath,
      displayName: fileName,
      mimeType: mimeType,
    );
    await _database.insertExportRecord(
      ExportRecord(
        id: _uuid.v4(),
        exportType: exportType,
        path: downloadsPath,
        rowCount: rowCount,
        createdAt: DateTime.now(),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported $rowCount rows')));
    }
    return _ExportedFile(
      path: downloadsPath,
      mimeType: mimeType,
      rowCount: rowCount,
    );
  }

  String _timestamp() {
    return DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .split('T')
        .join('_');
  }

  List<WebWhatsAppGroupCandidate> get _filteredWebGroups {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _webGroups;
    }
    return _webGroups
        .where((group) => group.name.toLowerCase().contains(query))
        .toList();
  }

  List<WebWhatsAppGroupCandidate> get _selectedWebGroups =>
      WebGroupSelection.selectedGroups(_webGroups, _selectedGroupIds);

  int get _selectedWebMemberEstimate {
    return _selectedWebGroups.fold<int>(
      0,
      (sum, group) =>
          sum +
          (group.members.isNotEmpty
              ? group.members.length
              : group.estimatedMemberCount),
    );
  }

  bool get _webNeedsLogin {
    final status = _webStatus.toLowerCase();
    return status.contains('login') ||
        status.contains('linked devices') ||
        status.contains('connect') ||
        status.contains('qr') ||
        status.contains('not connected');
  }

  bool get _selectedWebGroupsHaveNoMembers {
    final selected = _selectedWebGroups;
    return selected.isNotEmpty &&
        selected.every(
          (group) => group.members.isEmpty && group.estimatedMemberCount == 0,
        );
  }

  int get _activeWizardStep {
    if (_selectedSource == _ExtractorSource.phone) {
      if (_counts.groupMembers > 0) {
        return 2;
      }
      return 1;
    }
    if (_webGroups.isEmpty) {
      return 1;
    }
    if (_selectedGroupIds.isEmpty) {
      return 2;
    }
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WA Group Extractor'),
        actions: [
          IconButton(
            onPressed: _openAdvancedTools,
            tooltip: 'Advanced tools',
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            onPressed: _busy ? null : _refresh,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          _StatusBanner(status: _status, counts: _counts),
          Expanded(child: _buildWizardBody()),
        ],
      ),
    );
  }

  Future<void> _openAdvancedTools() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) {
          return DefaultTabController(
            length: 3,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Advanced tools'),
                bottom: const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.phone_android), text: 'Phone'),
                    Tab(icon: Icon(Icons.language), text: 'Web'),
                    Tab(icon: Icon(Icons.file_download), text: 'Exports'),
                  ],
                ),
              ),
              body: TabBarView(
                children: [
                  _buildPhoneTab(),
                  _buildWebTab(),
                  _buildExportsTab(),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) {
      await _refresh();
    }
  }

  Widget _buildWizardBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _WizardProgress(activeStep: _activeWizardStep),
        const SizedBox(height: 18),
        _buildSourceChoiceStep(),
        const SizedBox(height: 20),
        _buildCaptureStep(),
        const SizedBox(height: 20),
        _buildReviewStep(),
        const SizedBox(height: 20),
        _buildWizardExportStep(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildSourceChoiceStep() {
    return _WizardStepSection(
      step: 1,
      title: 'Choose source',
      subtitle:
          'Phone capture is the default path. WhatsApp Web is available for advanced bulk scans.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final choices = [
            _SourceChoiceButton(
              selected: _selectedSource == _ExtractorSource.phone,
              icon: Icons.phone_android,
              title: 'Phone capture',
              subtitle: 'Capture the group info already visible on this phone.',
              badge: 'Default',
              onTap: () =>
                  setState(() => _selectedSource = _ExtractorSource.phone),
            ),
            _SourceChoiceButton(
              selected: _selectedSource == _ExtractorSource.web,
              icon: Icons.language,
              title: 'Advanced bulk scan',
              subtitle: 'Link WhatsApp Web, scan groups, then save selected.',
              badge: 'Web',
              onTap: () =>
                  setState(() => _selectedSource = _ExtractorSource.web),
            ),
          ];
          if (compact) {
            return Column(
              children: [
                choices.first,
                const SizedBox(height: 10),
                choices.last,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: choices.first),
              const SizedBox(width: 12),
              Expanded(child: choices.last),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCaptureStep() {
    return _WizardStepSection(
      step: 2,
      title: _selectedSource == _ExtractorSource.phone
          ? 'Capture from phone'
          : 'Scan WhatsApp Web',
      subtitle: _selectedSource == _ExtractorSource.phone
          ? 'Enable the capture service, open WhatsApp group info, then return to review the staged batch.'
          : 'Connect a Web session, scan visible groups, then open group info when member details are not visible.',
      child: _selectedSource == _ExtractorSource.phone
          ? _buildPhoneCaptureWizardPanel()
          : _buildWebCaptureWizardPanel(),
    );
  }

  Widget _buildPhoneCaptureWizardPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ChecklistRow(
              icon: _accessibilityEnabled
                  ? Icons.check_circle
                  : Icons.error_outline,
              title: 'Capture Service',
              value: _accessibilityEnabled ? 'Enabled' : 'Required',
              tone: _accessibilityEnabled
                  ? _StatusTone.success
                  : _StatusTone.warning,
            ),
            const Divider(height: 20),
            const _ChecklistRow(
              icon: Icons.chat,
              title: 'WhatsApp',
              value: 'Open group info',
              tone: _StatusTone.info,
            ),
            const Divider(height: 20),
            _ChecklistRow(
              icon: Icons.fact_check,
              title: 'Latest saved data',
              value:
                  '${_counts.groups} groups, ${_counts.groupMembers} members',
              tone: _counts.groupMembers > 0
                  ? _StatusTone.success
                  : _StatusTone.neutral,
            ),
            const SizedBox(height: 14),
            if (!_accessibilityEnabled)
              _StatusCallout(
                icon: Icons.accessibility_new,
                title: 'Enable Capture Service',
                message:
                    'Turn on the WA Group Extractor capture service, then return here to open WhatsApp.',
                tone: _StatusTone.warning,
                action: FilledButton.icon(
                  onPressed: _busy ? null : _bridge.openAccessibilitySettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Enable Capture Service'),
                ),
              )
            else
              _ResponsiveActionBar(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _openWhatsApp,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open WhatsApp'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _loadLatestWhatsAppCapture,
                    icon: const Icon(Icons.fact_check),
                    label: const Text('Review Captured Group'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _manualImport,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Manual Import'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebCaptureWizardPanel() {
    final memberWarning =
        _webGroups.isNotEmpty &&
        _webGroups.every(
          (group) => group.members.isEmpty && group.estimatedMemberCount == 0,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusCallout(
          icon: _webNeedsLogin ? Icons.link_off : Icons.language,
          title: _webNeedsLogin ? 'Connect WhatsApp Web' : 'Web session status',
          message: _webStatus,
          tone: _webNeedsLogin ? _StatusTone.warning : _StatusTone.info,
          action: _webNeedsLogin
              ? FilledButton.icon(
                  onPressed: _busy ? null : _openFullScreenWebLogin,
                  icon: const Icon(Icons.open_in_full),
                  label: const Text('Full-screen login'),
                )
              : FilledButton.icon(
                  onPressed: _busy || _webLoading ? null : _scanWhatsAppWeb,
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Scan WhatsApp Web'),
                ),
        ),
        const SizedBox(height: 10),
        _ResponsiveActionBar(
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _openFullScreenWebLogin,
              icon: const Icon(Icons.open_in_full),
              label: const Text('Full-screen login'),
            ),
            OutlinedButton.icon(
              onPressed: _busy || _webLoading ? null : _scanWhatsAppWeb,
              icon: const Icon(Icons.travel_explore),
              label: const Text('Scan groups'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _reloadWhatsAppWeb,
              icon: const Icon(Icons.build_circle_outlined),
              label: const Text('Fix Web Connection'),
            ),
          ],
        ),
        if (memberWarning) ...[
          const SizedBox(height: 10),
          const _StatusCallout(
            icon: Icons.info_outline,
            title: 'Open group info to capture members',
            message:
                'The scan found group names but no visible member records. Open the group info page in WhatsApp Web, then scan again.',
            tone: _StatusTone.warning,
          ),
        ],
      ],
    );
  }

  Widget _buildReviewStep() {
    return _WizardStepSection(
      step: 3,
      title: 'Review selection',
      subtitle:
          'Check counts, visibility, admin roles, and duplicates before exporting.',
      child: _selectedSource == _ExtractorSource.phone
          ? _buildPhoneReviewPanel()
          : _buildWebGroupSelectionPanel(),
    );
  }

  Widget _buildPhoneReviewPanel() {
    if (_counts.groupMembers == 0) {
      return _EmptyStatePanel(
        icon: Icons.fact_check,
        title: 'No captured members saved yet',
        subtitle: _accessibilityEnabled
            ? 'Open WhatsApp group info, scroll visible members, then review the captured group.'
            : 'Enable the capture service first, then return here after opening WhatsApp.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetricStrip(
          metrics: [
            _MetricData(label: 'Groups', value: '${_counts.groups}'),
            _MetricData(label: 'Members', value: '${_counts.groupMembers}'),
            _MetricData(label: 'Contacts', value: '${_counts.contacts}'),
          ],
        ),
        const SizedBox(height: 10),
        const _StatusCallout(
          icon: Icons.visibility,
          title: 'Review phone visibility',
          message:
              'Phone capture saves numbers only when WhatsApp shows them on screen. Name-only rows export with low confidence.',
          tone: _StatusTone.info,
        ),
        const SizedBox(height: 10),
        _ResponsiveActionBar(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _loadLatestWhatsAppCapture,
              icon: const Icon(Icons.fact_check),
              label: const Text('Review Captured Group'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _importLocalContacts,
              icon: const Icon(Icons.contacts),
              label: const Text('Import Phone Contacts'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWizardExportStep() {
    return _WizardStepSection(
      step: 4,
      title: 'Export',
      subtitle:
          'Choose admin filter, dedupe behavior, and output format for the saved contacts.',
      child: _buildExportControls(showRecent: true),
    );
  }

  Widget _buildWebTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'WhatsApp Web Session',
          subtitle:
              'Connect your own WhatsApp Web session, scan available groups, then save only selected groups.',
        ),
        _buildWebActionPanel(),
        const SizedBox(height: 12),
        _InlineNotice(
          icon: Icons.info_outline,
          text:
              'If the QR screen is cramped, open full-screen login and rotate the phone. After linking, return here and scan.',
        ),
        const SizedBox(height: 12),
        _buildWebPreview(),
        const SizedBox(height: 16),
        _buildWebGroupSelectionPanel(),
      ],
    );
  }

  Widget _buildWebGroupSelectionPanel() {
    final visibleGroups = _filteredWebGroups;
    final selectedGroups = _selectedWebGroups;
    final selectedMemberEstimate = _selectedWebMemberEstimate;
    if (_webGroups.isEmpty) {
      return _EmptyStatePanel(
        icon: Icons.groups_2,
        title: _webScanAttempted
            ? 'No readable Web groups found'
            : 'No groups scanned yet',
        subtitle: _webScanAttempted
            ? 'Open a group chat or group info inside this Web session, then scan again.'
            : 'Use Full-screen login, then scan visible groups.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_selectedWebGroupsHaveNoMembers)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: _StatusCallout(
              icon: Icons.info_outline,
              title: 'Group names only',
              message:
                  'Open group info in WhatsApp Web and scan again to capture visible member names and numbers.',
              tone: _StatusTone.warning,
            ),
          ),
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: 'Search groups',
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _SelectionSummaryPanel(
          selectedGroupCount: selectedGroups.length,
          totalGroupCount: _webGroups.length,
          selectedMemberEstimate: selectedMemberEstimate,
          onSelectAll: _webGroups.isEmpty
              ? null
              : () => setState(() {
                  _selectedGroupIds = WebGroupSelection.selectAll(_webGroups);
                }),
          onClear: _webGroups.isEmpty
              ? null
              : () => setState(() => _selectedGroupIds = {}),
          onSave: _selectedGroupIds.isEmpty || _busy
              ? null
              : _saveSelectedWebGroups,
        ),
        const SizedBox(height: 8),
        if (visibleGroups.isEmpty)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.search_off),
            title: Text('No matching groups'),
            subtitle: Text('Clear the search field to see all scanned groups.'),
          )
        else
          for (final group in visibleGroups)
            CheckboxListTile(
              value: _selectedGroupIds.contains(group.whatsappId),
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _selectedGroupIds.add(group.whatsappId);
                  } else {
                    _selectedGroupIds.remove(group.whatsappId);
                  }
                });
              },
              title: Text(group.name.isEmpty ? group.whatsappId : group.name),
              subtitle: Text(
                '${group.members.length} extracted members, ${group.estimatedMemberCount} estimated',
              ),
              secondary: Icon(
                group.members.any((member) => member.phone.isNotEmpty)
                    ? Icons.contacts
                    : Icons.groups_2,
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
      ],
    );
  }

  Widget _buildWebActionPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _webStatus,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 520;
                Widget scanButton() => FilledButton.icon(
                  onPressed: _busy || _webLoading ? null : _scanWhatsAppWeb,
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Scan groups'),
                );
                Widget loginButton() => OutlinedButton.icon(
                  onPressed: _busy ? null : _openFullScreenWebLogin,
                  icon: const Icon(Icons.open_in_full),
                  label: const Text('Full-screen login'),
                );
                Widget reloadButton() => OutlinedButton.icon(
                  onPressed: _busy ? null : _reloadWhatsAppWeb,
                  icon: const Icon(Icons.build_circle_outlined),
                  label: const Text('Fix Web Connection'),
                );

                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      scanButton(),
                      const SizedBox(height: 8),
                      loginButton(),
                      const SizedBox(height: 8),
                      reloadButton(),
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(child: scanButton()),
                    const SizedBox(width: 10),
                    loginButton(),
                    const SizedBox(width: 10),
                    reloadButton(),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebPreview() {
    if (!widget.enableWebView) {
      return const _EmptyStatePanel(
        icon: Icons.language,
        title: 'Web preview unavailable',
        subtitle: 'Open the full app on Android to use WhatsApp Web scanning.',
      );
    }
    return SizedBox(
      height: 300,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              _ScaledWebView(controller: _webController),
              if (_webLoading) const LinearProgressIndicator(minHeight: 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader(
          title: 'Phone WhatsApp Capture',
          subtitle:
              'Use WhatsApp already installed on this phone. Open group info and scroll members to stage them for review.',
        ),
        _ActionRow(
          icon: _accessibilityEnabled
              ? Icons.verified_user
              : Icons.accessibility_new,
          title: _accessibilityEnabled
              ? 'Capture Service Enabled'
              : 'Enable Capture Service',
          subtitle: 'Required for on-phone WhatsApp group capture.',
          onPressed: _busy ? null : _bridge.openAccessibilitySettings,
        ),
        _ActionRow(
          icon: Icons.open_in_new,
          title: 'Open WhatsApp',
          subtitle: 'Open a group info page and scroll the members you want.',
          onPressed: _busy ? null : _openWhatsApp,
        ),
        _ActionRow(
          icon: Icons.fact_check,
          title: 'Review Captured Group',
          subtitle: 'Save the staged visible members after review.',
          onPressed: _busy ? null : _loadLatestWhatsAppCapture,
        ),
        _ActionRow(
          icon: Icons.contacts,
          title: 'Import Phone Contacts',
          subtitle: 'Merge saved phone contacts for better names.',
          onPressed: _busy ? null : _importLocalContacts,
        ),
        _ActionRow(
          icon: Icons.upload_file,
          title: 'Paste / CSV / vCard Import',
          subtitle: 'Import copied extractor output.',
          onPressed: _busy ? null : _manualImport,
        ),
      ],
    );
  }

  Widget _buildExportsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader(
          title: 'Export Options',
          subtitle:
              'Choose admin filter, role columns, dedupe, and output file format.',
        ),
        _buildExportControls(showRecent: true),
      ],
    );
  }

  Widget _buildExportControls({required bool showRecent}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<MemberRoleFilter>(
          segments: const [
            ButtonSegment(value: MemberRoleFilter.all, label: Text('All')),
            ButtonSegment(
              value: MemberRoleFilter.excludeAdmins,
              label: Text('No admins'),
            ),
            ButtonSegment(
              value: MemberRoleFilter.adminsOnly,
              label: Text('Admins'),
            ),
          ],
          selected: {_roleFilter},
          onSelectionChanged: (value) {
            setState(() => _roleFilter = value.single);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _includeRoleColumns,
          onChanged: (value) => setState(() => _includeRoleColumns = value),
          title: const Text('Include role/admin columns'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _dedupeExports,
          onChanged: (value) => setState(() => _dedupeExports = value),
          title: const Text('Deduplicate global contacts'),
        ),
        const SizedBox(height: 10),
        _ExportButtonGrid(
          busy: _busy,
          exportCsv: () => _exportCsv(
            exportType: 'csv',
            filePrefix: 'wa_group_contacts',
            roleFilter: _roleFilter,
            dedupe: _dedupeExports,
          ),
          exportAllCsv: () => _exportCsv(
            exportType: 'csv_all_members',
            filePrefix: 'wa_group_all_members',
            roleFilter: MemberRoleFilter.all,
            dedupe: false,
          ),
          exportNoAdminsCsv: () => _exportCsv(
            exportType: 'csv_without_admins',
            filePrefix: 'wa_group_without_admins',
            roleFilter: MemberRoleFilter.excludeAdmins,
            dedupe: _dedupeExports,
          ),
          exportAdminsCsv: () => _exportCsv(
            exportType: 'csv_admins_only',
            filePrefix: 'wa_group_admins',
            roleFilter: MemberRoleFilter.adminsOnly,
            dedupe: _dedupeExports,
          ),
          exportXlsx: _exportXlsx,
          exportVcard: _exportVcard,
          exportJson: _exportJson,
        ),
        const SizedBox(height: 18),
        if (showRecent) _RecentList(exports: _exports, runs: _runs),
      ],
    );
  }
}

class _ExportedFile {
  const _ExportedFile({
    required this.path,
    required this.mimeType,
    required this.rowCount,
  });

  final String path;
  final String mimeType;
  final int rowCount;
}

enum _StatusTone { neutral, info, success, warning, danger }

class _ToneColors {
  const _ToneColors({
    required this.background,
    required this.border,
    required this.foreground,
  });

  final Color background;
  final Color border;
  final Color foreground;
}

_ToneColors _toneColors(BuildContext context, _StatusTone tone) {
  final colorScheme = Theme.of(context).colorScheme;
  return switch (tone) {
    _StatusTone.info => _ToneColors(
      background: colorScheme.secondaryContainer,
      border: colorScheme.secondary.withValues(alpha: 0.35),
      foreground: colorScheme.onSecondaryContainer,
    ),
    _StatusTone.success => _ToneColors(
      background: colorScheme.primaryContainer,
      border: colorScheme.primary.withValues(alpha: 0.35),
      foreground: colorScheme.onPrimaryContainer,
    ),
    _StatusTone.warning => _ToneColors(
      background: colorScheme.tertiaryContainer,
      border: colorScheme.tertiary.withValues(alpha: 0.35),
      foreground: colorScheme.onTertiaryContainer,
    ),
    _StatusTone.danger => _ToneColors(
      background: colorScheme.errorContainer,
      border: colorScheme.error.withValues(alpha: 0.35),
      foreground: colorScheme.onErrorContainer,
    ),
    _StatusTone.neutral => _ToneColors(
      background: colorScheme.surfaceContainerHighest,
      border: colorScheme.outlineVariant,
      foreground: colorScheme.onSurfaceVariant,
    ),
  };
}

class _WizardProgress extends StatelessWidget {
  const _WizardProgress({required this.activeStep});

  final int activeStep;

  @override
  Widget build(BuildContext context) {
    const steps = ['Source', 'Capture', 'Review', 'Export'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var index = 0; index < steps.length; index += 1)
          _ProgressChip(
            label: steps[index],
            step: index + 1,
            active: index == activeStep,
            complete: index < activeStep,
          ),
      ],
    );
  }
}

class _ProgressChip extends StatelessWidget {
  const _ProgressChip({
    required this.label,
    required this.step,
    required this.active,
    required this.complete,
  });

  final String label;
  final int step;
  final bool active;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = active || complete;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              complete
                  ? Icons.check_circle
                  : active
                  ? Icons.radio_button_checked
                  : Icons.circle_outlined,
              size: 18,
              color: selected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              '$step. $label',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WizardStepSection extends StatelessWidget {
  const _WizardStepSection({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final int step;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: colorScheme.primary,
              child: Text(
                '$step',
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _SourceChoiceButton extends StatelessWidget {
  const _SourceChoiceButton({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = selected ? colorScheme.primary : colorScheme.outline;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.all(14),
        side: BorderSide(color: borderColor, width: selected ? 1.5 : 1),
        backgroundColor: selected
            ? colorScheme.primaryContainer
            : colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    _TinyStatusChip(
                      text: badge,
                      tone: selected
                          ? _StatusTone.success
                          : _StatusTone.neutral,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String title;
  final String value;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _toneColors(context, tone).foreground),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const SizedBox(width: 8),
        _TinyStatusChip(text: value, tone: tone),
      ],
    );
  }
}

class _TinyStatusChip extends StatelessWidget {
  const _TinyStatusChip({required this.text, required this.tone});

  final String text;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = _toneColors(context, tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _StatusCallout extends StatelessWidget {
  const _StatusCallout({
    required this.icon,
    required this.title,
    required this.message,
    required this.tone,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final _StatusTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = _toneColors(context, tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: colors.foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(message, style: TextStyle(color: colors.foreground)),
                    ],
                  ),
                ),
              ],
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: action),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResponsiveActionBar extends StatelessWidget {
  const _ResponsiveActionBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index += 1) ...[
                if (index > 0) const SizedBox(height: 8),
                children[index],
              ],
            ],
          );
        }
        return Wrap(spacing: 8, runSpacing: 8, children: children);
      },
    );
  }
}

class _MetricData {
  const _MetricData({required this.label, required this.value});

  final String label;
  final String value;
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metrics});

  final List<_MetricData> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        if (compact) {
          return Column(
            children: [
              for (var index = 0; index < metrics.length; index += 1) ...[
                if (index > 0) const SizedBox(height: 8),
                _MetricTile(data: metrics[index]),
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var index = 0; index < metrics.length; index += 1) ...[
              if (index > 0) const SizedBox(width: 8),
              Expanded(child: _MetricTile(data: metrics[index])),
            ],
          ],
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.data});

  final _MetricData data;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data.value,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              data.label,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionSummaryPanel extends StatelessWidget {
  const _SelectionSummaryPanel({
    required this.selectedGroupCount,
    required this.totalGroupCount,
    required this.selectedMemberEstimate,
    required this.onSelectAll,
    required this.onClear,
    required this.onSave,
  });

  final int selectedGroupCount;
  final int totalGroupCount;
  final int selectedMemberEstimate;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClear;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$selectedGroupCount selected / $totalGroupCount groups',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '$selectedMemberEstimate members currently estimated from selected groups',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            _ResponsiveActionBar(
              children: [
                OutlinedButton.icon(
                  onPressed: onSelectAll,
                  icon: const Icon(Icons.select_all),
                  label: const Text('Select all'),
                ),
                OutlinedButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.deselect),
                  label: const Text('Clear'),
                ),
                FilledButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save),
                  label: const Text('Save selected'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenWebLoginPage extends StatefulWidget {
  const _FullScreenWebLoginPage();

  @override
  State<_FullScreenWebLoginPage> createState() =>
      _FullScreenWebLoginPageState();
}

class _FullScreenWebLoginPageState extends State<_FullScreenWebLoginPage> {
  late final WebViewController _controller;

  bool _loading = true;
  String _status = 'Loading WhatsApp Web';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(WebWhatsAppExtractor.desktopUserAgent)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _status = 'Loading WhatsApp Web';
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() {
                _loading = false;
                _status =
                    'Use WhatsApp Linked Devices to connect. Rotate or pinch-zoom if the QR is small.';
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) {
              return;
            }
            if (mounted) {
              setState(() {
                _loading = false;
                _status = 'WebView load error: ${error.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://web.whatsapp.com/'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('WA Web Login'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: () {
              setState(() {
                _loading = true;
                _status = 'Reloading WhatsApp Web';
              });
              _controller.reload();
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Done',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 3),
            _InlineNotice(icon: Icons.qr_code_2, text: _status),
            Expanded(child: _ScaledWebView(controller: _controller)),
          ],
        ),
      ),
    );
  }
}

class _ScaledWebView extends StatelessWidget {
  const _ScaledWebView({required this.controller});

  static const double _desktopWidth = 1280;

  final WebViewController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _desktopWidth) {
          return WebViewWidget(controller: controller);
        }

        final scale = constraints.maxWidth / _desktopWidth;
        final unscaledHeight = constraints.maxHeight / scale;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: _desktopWidth,
            maxWidth: _desktopWidth,
            minHeight: unscaledHeight,
            maxHeight: unscaledHeight,
            child: Transform.scale(
              alignment: Alignment.topLeft,
              scale: scale,
              child: SizedBox(
                width: _desktopWidth,
                height: unscaledHeight,
                child: WebViewWidget(controller: controller),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, required this.counts});

  final String status;
  final ExporterCounts counts;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final countsText =
        '${counts.groups} groups  ${counts.groupMembers} members';
    return DecoratedBox(
      decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.dataset_linked),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          countsText,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                const Icon(Icons.dataset_linked),
                const SizedBox(width: 10),
                Expanded(child: Text(status, overflow: TextOverflow.ellipsis)),
                Text(
                  countsText,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: colorScheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStatePanel extends StatelessWidget {
  const _EmptyStatePanel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
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

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.all(12),
        ),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
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

class _ExportButtonGrid extends StatelessWidget {
  const _ExportButtonGrid({
    required this.busy,
    required this.exportCsv,
    required this.exportAllCsv,
    required this.exportNoAdminsCsv,
    required this.exportAdminsCsv,
    required this.exportXlsx,
    required this.exportVcard,
    required this.exportJson,
  });

  final bool busy;
  final VoidCallback exportCsv;
  final VoidCallback exportAllCsv;
  final VoidCallback exportNoAdminsCsv;
  final VoidCallback exportAdminsCsv;
  final VoidCallback exportXlsx;
  final VoidCallback exportVcard;
  final VoidCallback exportJson;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (Icons.table_view, 'CSV', 'Current filters', exportCsv),
      (Icons.groups_2, 'All CSV', 'All members', exportAllCsv),
      (Icons.group_remove, 'No Admins', 'Exclude admins', exportNoAdminsCsv),
      (Icons.admin_panel_settings, 'Admins', 'Admins only', exportAdminsCsv),
      (Icons.grid_on, 'XLSX', 'Spreadsheet', exportXlsx),
      (Icons.contact_mail, 'vCard', 'Contacts file', exportVcard),
      (Icons.data_object, 'JSON', 'Full backup', exportJson),
    ];
    return GridView.count(
      crossAxisCount: MediaQuery.sizeOf(context).width > 620 ? 3 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.55,
      children: [
        for (final action in actions)
          OutlinedButton(
            onPressed: busy ? null : action.$4,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(10),
              alignment: Alignment.centerLeft,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.$1),
                const SizedBox(height: 8),
                Text(
                  action.$2,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(action.$3, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
      ],
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({required this.exports, required this.runs});

  final List<ExportRecord> exports;
  final List<ExtractionRun> runs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Extraction Runs',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (runs.isEmpty) const ListTile(title: Text('No extraction runs yet')),
        for (final run in runs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text('${run.source} - ${run.selectedGroupCount} groups'),
            subtitle: Text('${run.memberCount} members - ${run.status.name}'),
          ),
        const SizedBox(height: 12),
        Text('Recent Files', style: Theme.of(context).textTheme.titleMedium),
        if (exports.isEmpty) const ListTile(title: Text('No exports yet')),
        for (final record in exports)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.file_present),
            title: Text(record.exportType),
            subtitle: Text(
              record.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text('${record.rowCount}'),
          ),
      ],
    );
  }
}

class _ReviewedCapture {
  const _ReviewedCapture({
    required this.groupName,
    required this.sourceAccountLabel,
    required this.members,
  });

  final String groupName;
  final String sourceAccountLabel;
  final List<GroupMember> members;
}

class _CaptureReviewSheet extends StatefulWidget {
  const _CaptureReviewSheet({required this.batch});

  final CaptureBatch batch;

  @override
  State<_CaptureReviewSheet> createState() => _CaptureReviewSheetState();
}

class _CaptureReviewSheetState extends State<_CaptureReviewSheet> {
  late final TextEditingController _groupName;
  late final TextEditingController _sourceAccount;
  late final List<_EditableMember> _members;

  @override
  void initState() {
    super.initState();
    _groupName = TextEditingController(
      text: widget.batch.groupName.isEmpty
          ? 'WhatsApp group'
          : widget.batch.groupName,
    );
    _sourceAccount = TextEditingController(
      text: widget.batch.sourceAccountLabel,
    );
    _members = widget.batch.members
        .map((member) => _EditableMember.fromMember(member))
        .toList();
  }

  @override
  void dispose() {
    _groupName.dispose();
    _sourceAccount.dispose();
    for (final member in _members) {
      member.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.55,
        builder: (context, scrollController) {
          return ListView(
            controller: scrollController,
            children: [
              Row(
                children: [
                  const Icon(Icons.fact_check),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Review Extracted Members',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _groupName,
                decoration: const InputDecoration(labelText: 'Group name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _sourceAccount,
                decoration: const InputDecoration(
                  labelText: 'Source account / package',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('Select all'),
                    onPressed: () => _setIncluded(true),
                  ),
                  ActionChip(
                    label: const Text('Numbers only'),
                    onPressed: _numbersOnly,
                  ),
                  ActionChip(
                    label: const Text('Mark unknown'),
                    onPressed: _markUnknown,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              for (final member in _members) _MemberEditor(member: member),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('Save Batch'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  void _setIncluded(bool included) {
    setState(() {
      for (final member in _members) {
        member.include = included;
      }
    });
  }

  void _numbersOnly() {
    setState(() {
      for (final member in _members) {
        member.include = member.phone.text.trim().isNotEmpty;
      }
    });
  }

  void _markUnknown() {
    setState(() {
      for (final member in _members) {
        if (member.role != ContactRole.admin) {
          member.role = ContactRole.unknown;
        }
      }
    });
  }

  void _save() {
    final reviewedMembers = _members
        .where((member) => member.include)
        .map(
          (member) => GroupMember(
            id: '',
            groupId: '',
            displayName: member.name.text.trim(),
            phone: member.phone.text.trim(),
            normalizedPhone: PhoneNormalizer.normalize(member.phone.text),
            role: member.role,
            confidence: member.confidence,
            source: member.source,
            phoneVisibility: member.phone.text.trim().isEmpty
                ? PhoneVisibility.notVisible
                : PhoneVisibility.visible,
            isAdmin: member.role == ContactRole.admin,
          ),
        )
        .where(
          (member) => member.displayName.isNotEmpty || member.phone.isNotEmpty,
        )
        .toList();
    Navigator.pop(
      context,
      _ReviewedCapture(
        groupName: _groupName.text.trim().isEmpty
            ? 'WhatsApp group'
            : _groupName.text.trim(),
        sourceAccountLabel: _sourceAccount.text.trim(),
        members: reviewedMembers,
      ),
    );
  }
}

class _MemberEditor extends StatefulWidget {
  const _MemberEditor({required this.member});

  final _EditableMember member;

  @override
  State<_MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<_MemberEditor> {
  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Checkbox(
                    value: member.include,
                    onChanged: (value) {
                      setState(() {
                        member.include = value ?? true;
                      });
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: member.name,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: member.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone if visible',
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ContactRole>(
                initialValue: member.role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: ContactRole.values
                    .map(
                      (role) =>
                          DropdownMenuItem(value: role, child: Text(role.name)),
                    )
                    .toList(),
                onChanged: (role) {
                  setState(() {
                    member.role = role ?? ContactRole.unknown;
                  });
                },
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Capture confidence: ${member.confidence}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditableMember {
  _EditableMember({
    required this.include,
    required this.name,
    required this.phone,
    required this.role,
    required this.confidence,
    required this.source,
  });

  bool include;
  final TextEditingController name;
  final TextEditingController phone;
  ContactRole role;
  final String confidence;
  final String source;

  factory _EditableMember.fromMember(GroupMember member) {
    return _EditableMember(
      include: true,
      name: TextEditingController(text: member.displayName),
      phone: TextEditingController(text: member.phone),
      role: member.role,
      confidence: member.confidence,
      source: member.source,
    );
  }

  void dispose() {
    name.dispose();
    phone.dispose();
  }
}

class _ManualImportDialog extends StatefulWidget {
  const _ManualImportDialog();

  @override
  State<_ManualImportDialog> createState() => _ManualImportDialogState();
}

class _ManualImportDialogState extends State<_ManualImportDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste Extractor Data'),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: _controller,
          minLines: 8,
          maxLines: 14,
          decoration: const InputDecoration(
            hintText: 'Paste names, phone numbers, CSV rows, or vCards',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
