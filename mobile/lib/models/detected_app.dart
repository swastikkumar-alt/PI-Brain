import 'package:flutter/material.dart';

class DetectedApp {
  const DetectedApp({
    required this.id,
    required this.name,
    required this.packageName,
    required this.installed,
    required this.capability,
    required this.status,
    required this.icon,
  });

  final String id;
  final String name;
  final String packageName;
  final bool installed;
  final String capability;
  final String status;
  final IconData icon;

  factory DetectedApp.fromJson(Map<dynamic, dynamic> json) {
    return DetectedApp(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Unknown app',
      packageName: json['packageName']?.toString() ?? '',
      installed: json['installed'] == true,
      capability: json['capability']?.toString() ?? 'No connector available',
      status: json['status']?.toString() ?? 'Not installed',
      icon: _iconFor(json['id']?.toString() ?? ''),
    );
  }
}

IconData _iconFor(String id) {
  return switch (id) {
    'whatsapp' => Icons.chat_outlined,
    'whatsapp_business' => Icons.business_center_outlined,
    'gmail' => Icons.mail_outline,
    'samsung_health' => Icons.favorite_border,
    'health_connect' => Icons.health_and_safety_outlined,
    'google_fit' => Icons.directions_run_outlined,
    'digital_wellbeing' => Icons.self_improvement_outlined,
    'samsung_email' => Icons.alternate_email,
    'gemini' => Icons.auto_awesome,
    'chatgpt' => Icons.smart_toy_outlined,
    _ => Icons.apps_outlined,
  };
}
