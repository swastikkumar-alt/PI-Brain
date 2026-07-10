import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import '../models/message.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';

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
      await _loadMessages();
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
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  bottom: 8,
                                ),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: msg.citations.map((citation) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.blueAccent.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.blueAccent.withValues(
                                            alpha: 0.3,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.bookmark_outline,
                                            size: 12,
                                            color: Colors.blueAccent,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            citation.title,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Colors.blueAccent,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
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
