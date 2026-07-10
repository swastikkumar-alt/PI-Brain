import 'package:flutter/material.dart';

class IntroView extends StatelessWidget {
  const IntroView({super.key, required this.onContinue});

  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [
                      Color(0xFF0B1020),
                      Color(0xFF111827),
                      Color(0xFF052E2B),
                    ]
                  : const [
                      Color(0xFFF8FAFC),
                      Color(0xFFEFF6FF),
                      Color(0xFFF0FDF4),
                    ],
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
            children: [
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      image: const DecorationImage(
                        image: AssetImage('assets/images/logo.png'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PIE Mobile',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Private intelligence for your phone',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                'Understand your phone. Act only after you approve.',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  height: 1.08,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'PIE connects to the data sources you choose, answers questions from local phone context, drafts messages, and opens approved app actions with verification.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: isDark ? Colors.white70 : const Color(0xFF475569),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              _CapabilityCard(
                icon: Icons.search_outlined,
                title: 'Ask about local context',
                body:
                    'Spend, orders, delivery updates, PDFs, SMS and notification context after you enable those sources.',
                accent: const Color(0xFF2563EB),
                isDark: isDark,
              ),
              _CapabilityCard(
                icon: Icons.edit_note_outlined,
                title: 'Draft before sending',
                body:
                    'WhatsApp and email commands become editable drafts first. PIE keeps the intended tone and language.',
                accent: const Color(0xFF16A34A),
                isDark: isDark,
              ),
              _CapabilityCard(
                icon: Icons.verified_user_outlined,
                title: 'Approval and safety',
                body:
                    'Sensitive actions require confirmation. PIE does not silently send, delete, block, or bypass locked apps.',
                accent: const Color(0xFFF59E0B),
                isDark: isDark,
              ),
              _CapabilityCard(
                icon: Icons.tune_outlined,
                title: 'You choose the access',
                body:
                    'Settings is where you enable sources, permissions, phone action service, and light or dark appearance.',
                accent: const Color(0xFF7C3AED),
                isDark: isDark,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onContinue,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Continue to Home'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'You can reopen this guide anytime from Settings.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
    required this.isDark,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color accent;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
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
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : const Color(0xFF475569),
                    height: 1.38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
