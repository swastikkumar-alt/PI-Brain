import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import '../models/message.dart';
import '../models/entity.dart';
import '../models/detected_app.dart';
import '../services/agent_service.dart';
import '../services/app_discovery_service.dart';
import '../services/database_service.dart';
import '../services/image_generation_service.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AgentService _agent = AgentService();
  final AppDiscoveryService _appDiscovery = AppDiscoveryService.instance;
  final String _conversationId = const Uuid().v4();

  List<Message> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    final msgs = await DatabaseService.instance.getMessages(_conversationId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  File? _attachedFile;

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform
        .pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf', 'txt', 'png', 'jpg', 'jpeg'],
        )
        .catchError((_) => null);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _attachedFile = File(result.files.single.path!);
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachedFile == null) return;

    final attachedFile = _attachedFile;
    _controller.clear();
    setState(() {
      _attachedFile = null;
      _isLoading = true;
    });

    try {
      // Run model-backed response pipeline. No local fallback reply is allowed.
      await _agent.thinkAndRespond(text, _conversationId, attachedFile);
      final handoff = _agent.consumePendingImageHandoff();
      await _loadMessages();
      if (handoff != null && mounted) {
        await _showImageHandoffSheet(handoff);
      }
    } catch (_) {
      await _loadMessages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Model/backend unavailable. No local fallback response was used.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showImageHandoffSheet(ImageGenerationResult handoff) async {
    final prompt = handoff.handoffPrompt ?? '';
    if (prompt.trim().isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
            child: FutureBuilder(
              future: _appDiscovery.listSupportedApps(),
              builder: (context, snapshot) {
                final apps =
                    (snapshot.data ?? const [])
                        .where(
                          (app) => app.id == 'gemini' || app.id == 'chatgpt',
                        )
                        .toList()
                      ..sort((a, b) {
                        const order = {'gemini': 0, 'chatgpt': 1};
                        return (order[a.id] ?? 99).compareTo(order[b.id] ?? 99);
                      });
                return ImageHandoffSheet(
                  reason: handoff.handoffReason ?? 'Image handoff required.',
                  prompt: prompt,
                  apps: apps,
                  onOpenApp: (appId) async {
                    final result = await _appDiscovery.handoffPromptToAiApp(
                      prompt,
                      preferredAppId: appId,
                    );
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(result.message)));
                  },
                  onCopyPrompt: () async {
                    await Clipboard.setData(ClipboardData(text: prompt));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Prompt copied.')),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PIE Chat',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Model response required',
                    style: TextStyle(fontSize: 12, color: Colors.blueAccent),
                  ),
                ],
              ),
              elevation: 0,
              backgroundColor: Colors.transparent,
            )
          : null,
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
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.psychology,
                            size: 64,
                            color: Colors.blueAccent.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Ask anything. The configured model must respond.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        final isMe = msg.sender == MessageSender.user;
                        return Column(
                          crossAxisAlignment: isMe
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.all(14),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? Colors.blueAccent
                                    : (isDark
                                          ? const Color(0xFF2E2E3E)
                                          : Colors.white),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isMe ? 16 : 0),
                                  bottomRight: Radius.circular(isMe ? 0 : 16),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: MarkdownBody(
                                data: msg.text,
                                styleSheet:
                                    MarkdownStyleSheet.fromTheme(
                                      Theme.of(context),
                                    ).copyWith(
                                      p: TextStyle(
                                        color: isMe
                                            ? Colors.white
                                            : (isDark
                                                  ? Colors.white70
                                                  : Colors.black87),
                                        fontSize: 15,
                                      ),
                                    ),
                              ),
                            ),
                            if (!isMe && msg.citations.isNotEmpty)
                              EvidenceAccordion(
                                key: ValueKey('evidence_accordion_${msg.id}'),
                                citations: msg.citations,
                              ),
                          ],
                        );
                      },
                    ),
            ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (_attachedFile != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: isDark ? const Color(0xFF161622) : Colors.white,
                child: Row(
                  children: [
                    Icon(
                      _attachedFile!.path.endsWith('.pdf')
                          ? Icons.picture_as_pdf
                          : Icons.image,
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.basename(_attachedFile!.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => setState(() => _attachedFile = null),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161622) : Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    offset: const Offset(0, -2),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      onPressed: _pickAttachment,
                      color: Colors.blueAccent,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? const Color(0xFF252538)
                              : const Color(0xFFE5E7EB),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton(
                      onPressed: _sendMessage,
                      mini: true,
                      child: const Icon(Icons.send, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ImageHandoffSheet extends StatelessWidget {
  const ImageHandoffSheet({
    super.key,
    required this.reason,
    required this.prompt,
    required this.apps,
    required this.onOpenApp,
    required this.onCopyPrompt,
  });

  final String reason;
  final String prompt;
  final List<DetectedApp> apps;
  final Future<void> Function(String appId) onOpenApp;
  final Future<void> Function() onCopyPrompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Continue Image Generation',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(reason, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Text(
          'PIE can open an installed AI app with this prompt. The generated image remains inside that app until you save or share it back.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.56,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            prompt,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        for (final app in apps)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: app.installed ? () => onOpenApp(app.id) : null,
                icon: Icon(app.icon, size: 19),
                label: Text(
                  app.installed
                      ? 'Open ${app.name}'
                      : '${app.name} not installed',
                ),
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: onCopyPrompt,
            icon: const Icon(Icons.copy_outlined, size: 19),
            label: const Text('Copy Prompt'),
          ),
        ),
      ],
    );
  }
}

class EvidenceAccordion extends StatelessWidget {
  const EvidenceAccordion({
    super.key,
    required this.citations,
    this.evidenceLoader,
  });

  final List<Citation> citations;
  final Future<List<Entity>> Function(List<String> ids)? evidenceLoader;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ids = citations.map((citation) => citation.documentId).toList();

    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8, right: 48),
      child: FutureBuilder<List<Entity>>(
        future: (evidenceLoader ?? DatabaseService.instance.getEntitiesByIds)(
          ids,
        ),
        builder: (context, snapshot) {
          final entities = snapshot.data ?? const <Entity>[];
          final byId = {for (final entity in entities) entity.id: entity};
          final rows = [
            for (final citation in citations)
              _EvidenceRowData(
                citation: citation,
                entity: byId[citation.documentId],
              ),
          ];

          return Material(
            color: isDark ? const Color(0xFF151A24) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.08),
              ),
              child: ExpansionTile(
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                leading: const Icon(Icons.fact_check_outlined, size: 20),
                title: Text(
                  'Evidence (${citations.length})',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  _sourceSummary(rows),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
                children: snapshot.connectionState == ConnectionState.waiting
                    ? const [
                        Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      ]
                    : rows
                          .map(
                            (row) => _EvidenceListTile(
                              data: row,
                              onTap: () => _showEvidenceSheet(context, row),
                            ),
                          )
                          .toList(),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _sourceSummary(List<_EvidenceRowData> rows) {
    final counts = <String, int>{};
    for (final row in rows) {
      final source = row.entity?.sourceConnector ?? 'missing';
      counts[source] = (counts[source] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'Tap to review supporting local data';
    return counts.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(' · ');
  }

  static void _showEvidenceSheet(BuildContext context, _EvidenceRowData row) {
    final entity = row.entity;
    final text = _redactedEvidenceText(row);
    final parsedSpend = _parseSpendEvidence(row);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomPadding),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.72,
              minChildSize: 0.38,
              maxChildSize: 0.92,
              builder: (context, scrollController) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy evidence',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Evidence copied.')),
                            );
                          },
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _EvidenceMetaChip(
                          icon: Icons.storage_outlined,
                          label: entity?.sourceConnector ?? 'missing',
                        ),
                        _EvidenceMetaChip(
                          icon: Icons.category_outlined,
                          label: entity?.entityType ?? 'unknown',
                        ),
                        _EvidenceMetaChip(
                          icon: Icons.schedule_outlined,
                          label: entity == null
                              ? 'no timestamp'
                              : _formatEvidenceTime(entity.createdAt),
                        ),
                      ],
                    ),
                    if (parsedSpend.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: parsedSpend.entries
                            .map(
                              (entry) => _EvidenceMetaChip(
                                icon: entry.key == 'Amount'
                                    ? Icons.currency_rupee
                                    : Icons.receipt_long_outlined,
                                label: '${entry.key}: ${entry.value}',
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: scrollController,
                        child: SelectableText(
                          text,
                          style: const TextStyle(height: 1.45),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  static String _redactedEvidenceText(_EvidenceRowData row) {
    final raw =
        row.entity?.content ??
        'This evidence item is no longer available locally.';
    if (!row.title.toLowerCase().contains('spend evidence')) return raw;
    return raw
        .replaceAllMapped(
          RegExp(r'\b\d{10,}\b'),
          (match) => '${match.group(0)!.substring(0, 4)}...redacted',
        )
        .replaceAllMapped(
          RegExp(r'\b(?:a/c|account)\s*(?:no\.?)?\s*([xX*\d]{3,})'),
          (match) => 'A/c ...redacted',
        );
  }

  static Map<String, String> _parseSpendEvidence(_EvidenceRowData row) {
    if (!row.title.toLowerCase().contains('spend evidence')) return const {};
    final content = row.entity?.content ?? '';
    final amount = RegExp(
      r'(?:\u20B9|rs\.?|inr)\s*([0-9][0-9,]*(?:\.\d{1,2})?)|([0-9][0-9,]*(?:\.\d{1,2})?)\s*(?:\u20B9|rs\.?|inr)',
      caseSensitive: false,
    ).firstMatch(content);
    final reference = RegExp(
      r'\b(?:upi\s+ref(?:erence)?|utr|txn(?:\s*id)?|transaction\s*id|ref(?:\s*no\.?)?)[:\s-]*([a-z0-9]{6,})',
      caseSensitive: false,
    ).firstMatch(content);
    return {
      if (amount != null) 'Amount': amount.group(1) ?? amount.group(2) ?? '',
      if (reference != null) 'Ref': '${reference.group(1)!.substring(0, 4)}...',
    };
  }
}

class _EvidenceListTile extends StatelessWidget {
  const _EvidenceListTile({required this.data, required this.onTap});

  final _EvidenceRowData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final entity = data.entity;
    final source = entity?.sourceConnector ?? 'missing';
    final content = entity?.content?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.description_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    content == null || content.isEmpty
                        ? 'Evidence unavailable'
                        : content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  source,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EvidenceMetaChip extends StatelessWidget {
  const _EvidenceMetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceRowData {
  const _EvidenceRowData({required this.citation, required this.entity});

  final Citation citation;
  final Entity? entity;

  String get title =>
      citation.title.isEmpty ? citation.documentId : citation.title;
}

String _formatEvidenceTime(int millis) {
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$day/$month/${date.year} $hour:$minute';
}
