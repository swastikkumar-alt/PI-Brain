import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/phone_action.dart';
import '../services/action_approval_controller.dart';
import '../services/message_drafting_service.dart';
import '../services/voice_service.dart';

class AgentControlView extends StatefulWidget {
  const AgentControlView({
    super.key,
    this.onOpenSettings,
    this.showAppBar = true,
  });

  final VoidCallback? onOpenSettings;
  final bool showAppBar;

  @override
  State<AgentControlView> createState() => _AgentControlViewState();
}

class _AgentControlViewState extends State<AgentControlView> {
  final _commandController = TextEditingController();
  final _actionController = ActionApprovalController();
  final _voice = VoiceService.instance;
  final _draftingService = const MessageDraftingService();

  bool _isListening = false;
  bool _isPlanning = false;
  String _liveTranscript = '';
  String _statusText = 'Ready for push-to-talk commands.';

  @override
  void initState() {
    super.initState();
    _voice.onPartialTranscript = _handlePartialTranscript;
    _voice.onFinalTranscript = _handleFinalTranscript;
    _voice.onError = _handleVoiceError;
  }

  void _handlePartialTranscript(String text) {
    if (!mounted) return;
    setState(() {
      _liveTranscript = text;
    });
  }

  void _handleFinalTranscript(String text) {
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _liveTranscript = text;
      _commandController.text = text;
    });
    _planCommand(text);
  }

  void _handleVoiceError(String text) {
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _statusText = text;
    });
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _voice.stopListening();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    if (!await _voice.checkPermission()) {
      await _voice.requestPermission();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!await _voice.checkPermission()) {
        if (!mounted) return;
        setState(() {
          _statusText = 'Microphone permission is required for voice commands.';
        });
        return;
      }
    }

    setState(() {
      _isListening = true;
      _liveTranscript = '';
      _statusText = 'Listening...';
    });
    await _voice.startListening();
  }

  Future<void> _planCommand(String rawCommand) async {
    final command = rawCommand.trim();
    if (command.isEmpty || _isPlanning) return;

    setState(() {
      _isPlanning = true;
      _statusText = 'Planning action...';
    });

    try {
      final result = await _actionController.planCommand(command);
      if (!mounted) return;

      if (!result.hasPlan) {
        setState(() {
          _statusText = result.unsupportedReason ?? 'Unsupported command.';
        });
        await _voice.speak(_statusText);
        return;
      }

      final plan = result.plan!;
      if (plan.candidates.isNotEmpty) {
        await _showContactPicker(plan);
      } else if (plan.isBlocked) {
        _showBlockedPlan(plan);
      } else {
        await _showApprovalSheet(plan);
      }
    } finally {
      if (mounted) {
        setState(() => _isPlanning = false);
      }
    }
  }

  void _showBlockedPlan(PhoneActionPlan plan) {
    setState(() {
      _statusText = plan.blockedReason ?? 'Action is blocked.';
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_statusText)));
  }

  Future<void> _showContactPicker(PhoneActionPlan plan) async {
    final selected = await showModalBottomSheet<ContactCandidate>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const Text(
                'Choose Contact',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                plan.candidates.length == 1
                    ? 'PIE found a similar contact for "${plan.recipientQuery}". Confirm before continuing.'
                    : 'Multiple contacts matched "${plan.recipientQuery}".',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              ...plan.candidates.map(
                (candidate) => ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(candidate.displayName),
                  subtitle: Text(
                    candidate.emailAddress.isNotEmpty
                        ? candidate.emailAddress
                        : candidate.phoneNumber,
                  ),
                  onTap: () => Navigator.pop(context, candidate),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected == null || !mounted) {
      await _actionController.cancel(plan);
      setState(() => _statusText = 'Action cancelled.');
      return;
    }

    final updatedPlan = await _actionController.chooseCandidate(plan, selected);
    if (!mounted) return;
    await _showApprovalSheet(updatedPlan);
  }

  Future<void> _showApprovalSheet(PhoneActionPlan plan) async {
    final draftController = TextEditingController(text: plan.outgoingText);
    final subjectController = TextEditingController(
      text: plan.emailSubject ?? 'Update',
    );
    var relationshipType = plan.relationshipType;
    var tone = plan.tone;
    var attachmentPaths = List<String>.from(plan.emailAttachmentPaths);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final contact = plan.contact;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void regenerateDraft() {
              final draft = _draftingService.createDraft(
                rawMessage: plan.messageBody,
                actionType: plan.type,
                relationshipType: relationshipType,
                requestedTone: tone,
                recipientName: contact?.safeLabel,
                intent: plan.intent,
              );
              plan.language = draft.language;
              plan.emailSubject = draft.subject;
              draftController.text = draft.body;
              subjectController.text = draft.subject ?? subjectController.text;
            }

            Future<void> pickEmailAttachments() async {
              final result = await FilePicker.platform
                  .pickFiles(
                    allowMultiple: true,
                    type: FileType.custom,
                    allowedExtensions: [
                      'pdf',
                      'doc',
                      'docx',
                      'txt',
                      'jpg',
                      'jpeg',
                      'png',
                      'xls',
                      'xlsx',
                    ],
                  )
                  .catchError((_) => null);
              if (result == null) return;
              final pickedPaths = result.files
                  .where((file) => file.path != null)
                  .map((file) => file.path!)
                  .where((path) => File(path).existsSync())
                  .toList();
              if (pickedPaths.isEmpty) return;
              setSheetState(() {
                attachmentPaths = {...attachmentPaths, ...pickedPaths}.toList();
                plan.emailAttachmentPaths = attachmentPaths;
              });
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  8,
                  20,
                  MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Approve Action',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        plan.type == PhoneActionType.emailMessage
                            ? 'PIE will open email compose. You send from the email app.'
                            : 'PIE will verify WhatsApp before tapping Send.',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 20),
                      _PreviewRow(
                        icon: plan.type == PhoneActionType.emailMessage
                            ? Icons.email_outlined
                            : Icons.chat_outlined,
                        label: 'App',
                        value: _channelLabel(plan),
                      ),
                      _PreviewRow(
                        icon: Icons.person_outline,
                        label: 'Recipient',
                        value: contact?.safeLabel ?? plan.recipientQuery,
                      ),
                      _PreviewRow(
                        icon: Icons.psychology_outlined,
                        label: 'Intent',
                        value:
                            '${plan.intent} / ${_languageLabel(plan.language)}',
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<RelationshipType>(
                        initialValue: relationshipType,
                        decoration: const InputDecoration(
                          labelText: 'Relationship',
                          border: OutlineInputBorder(),
                        ),
                        items: RelationshipType.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_relationshipLabel(value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setSheetState(() {
                            relationshipType = value;
                            tone = _draftingService.defaultToneForRelationship(
                              value,
                            );
                            regenerateDraft();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<MessageTone>(
                        initialValue: tone,
                        decoration: const InputDecoration(
                          labelText: 'Tone',
                          border: OutlineInputBorder(),
                        ),
                        items: MessageTone.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_toneLabel(value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setSheetState(() {
                            tone = value;
                            regenerateDraft();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (plan.type == PhoneActionType.emailMessage) ...[
                        TextField(
                          controller: subjectController,
                          decoration: const InputDecoration(
                            labelText: 'Subject',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (plan.emailAttachmentRequested ||
                            attachmentPaths.isNotEmpty) ...[
                          Text(
                            plan.emailAttachmentHint?.isNotEmpty == true
                                ? 'Attachment requested: ${plan.emailAttachmentHint}'
                                : 'Attachment requested',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                        ],
                        OutlinedButton.icon(
                          onPressed: pickEmailAttachments,
                          icon: const Icon(Icons.attach_file),
                          label: Text(
                            attachmentPaths.isEmpty
                                ? 'Add attachment'
                                : 'Add more attachments',
                          ),
                        ),
                        if (attachmentPaths.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ...attachmentPaths.map(
                            (path) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.description_outlined),
                              title: Text(
                                p.basename(path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  setSheetState(() {
                                    attachmentPaths = attachmentPaths
                                        .where((item) => item != path)
                                        .toList();
                                    plan.emailAttachmentPaths = attachmentPaths;
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: draftController,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Final message',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await _actionController.cancel(plan);
                                if (context.mounted) Navigator.pop(context);
                                if (mounted) {
                                  setState(
                                    () => _statusText = 'Action cancelled.',
                                  );
                                }
                              },
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.verified_outlined),
                              label: const Text('Approve'),
                              onPressed: () async {
                                final navigator = Navigator.of(context);
                                await _actionController.updateDraftPreferences(
                                  plan,
                                  relationshipType: relationshipType,
                                  tone: tone,
                                  finalText: draftController.text.trim(),
                                  emailSubject: subjectController.text.trim(),
                                  emailAttachmentPaths: attachmentPaths,
                                );
                                navigator.pop();
                                await _executePlan(plan);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    draftController.dispose();
    subjectController.dispose();
  }

  Future<void> _executePlan(PhoneActionPlan plan) async {
    setState(
      () => _statusText = plan.type == PhoneActionType.emailMessage
          ? 'Opening email compose for review...'
          : 'Opening WhatsApp for verified send...',
    );
    final result = await _actionController.approveAndExecute(plan);
    if (!mounted) return;
    setState(() => _statusText = result.message);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
    await _voice.speak(result.isSuccess ? 'Message sent.' : result.message);
  }

  String _channelLabel(PhoneActionPlan plan) {
    return plan.type == PhoneActionType.emailMessage ? 'Email' : 'WhatsApp';
  }

  String _languageLabel(MessageLanguage language) {
    return switch (language) {
      MessageLanguage.english => 'English',
      MessageLanguage.hindi => 'Hindi',
      MessageLanguage.hinglish => 'Hinglish',
      MessageLanguage.unknown => 'Unknown language',
    };
  }

  String _relationshipLabel(RelationshipType relationshipType) {
    return switch (relationshipType) {
      RelationshipType.family => 'Family',
      RelationshipType.friend => 'Friend',
      RelationshipType.professional => 'Professional',
      RelationshipType.custom => 'Custom',
      RelationshipType.unknown => 'Unknown',
    };
  }

  String _toneLabel(MessageTone tone) {
    return switch (tone) {
      MessageTone.friendly => 'Friendly',
      MessageTone.professional => 'Professional',
      MessageTone.neutral => 'Neutral',
      MessageTone.custom => 'Custom',
    };
  }

  @override
  void dispose() {
    if (_voice.onPartialTranscript == _handlePartialTranscript) {
      _voice.onPartialTranscript = null;
    }
    if (_voice.onFinalTranscript == _handleFinalTranscript) {
      _voice.onFinalTranscript = null;
    }
    if (_voice.onError == _handleVoiceError) {
      _voice.onError = null;
    }
    _commandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text(
                'PIE Device Actions',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              actions: [
                IconButton(
                  tooltip: 'Settings',
                  onPressed: widget.onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E2C) : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              children: [
                Icon(
                  _isListening ? Icons.graphic_eq : Icons.mic_none,
                  size: 42,
                  color: _isListening ? Colors.greenAccent : Colors.blueAccent,
                ),
                const SizedBox(height: 12),
                Text(
                  _isListening ? 'Listening' : 'Push To Talk',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _liveTranscript.isEmpty ? _statusText : _liveTranscript,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isPlanning ? null : _toggleListening,
                    icon: Icon(_isListening ? Icons.stop : Icons.mic),
                    label: Text(_isListening ? 'Stop' : 'Start Listening'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _commandController,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Command',
              hintText:
                  'message nalayak that i am not coming today on whatsapp',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: IconButton(
                tooltip: 'Plan command',
                onPressed: _isPlanning
                    ? null
                    : () => _planCommand(_commandController.text),
                icon: _isPlanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward),
              ),
            ),
            onSubmitted: _planCommand,
          ),
          const SizedBox(height: 16),
          Text(
            _statusText,
            style: TextStyle(
              color:
                  _statusText.toLowerCase().contains('failed') ||
                      _statusText.toLowerCase().contains('required')
                  ? Colors.orangeAccent
                  : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.blueAccent, size: 20),
          const SizedBox(width: 12),
          SizedBox(
            width: 86,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
