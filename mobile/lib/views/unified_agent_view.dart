import 'package:flutter/material.dart';

import 'agent_control_view.dart';
import 'chat_view.dart';

class UnifiedAgentView extends StatelessWidget {
  const UnifiedAgentView({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PIE Agent', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(
                'Chat and device actions',
                style: TextStyle(fontSize: 12, color: Colors.blueAccent),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.forum_outlined), text: 'Chat'),
              Tab(icon: Icon(Icons.smart_toy_outlined), text: 'Actions'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const ChatView(showAppBar: false),
            AgentControlView(showAppBar: false, onOpenSettings: onOpenSettings),
          ],
        ),
      ),
    );
  }
}
