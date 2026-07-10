import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/detected_app.dart';

class AiAppHandoffResult {
  const AiAppHandoffResult({
    required this.opened,
    required this.providerName,
    required this.packageName,
    required this.copiedToClipboard,
    required this.message,
  });

  final bool opened;
  final String providerName;
  final String packageName;
  final bool copiedToClipboard;
  final String message;

  factory AiAppHandoffResult.fromJson(Map<dynamic, dynamic> json) {
    return AiAppHandoffResult(
      opened: json['opened'] == true,
      providerName: json['providerName']?.toString() ?? '',
      packageName: json['packageName']?.toString() ?? '',
      copiedToClipboard: json['copiedToClipboard'] == true,
      message: json['message']?.toString() ?? '',
    );
  }
}

class AppDiscoveryService {
  AppDiscoveryService._init();

  static final AppDiscoveryService instance = AppDiscoveryService._init();

  static const MethodChannel _channel = MethodChannel('pie_mobile/apps');

  Future<List<DetectedApp>> listSupportedApps() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('listSupportedApps') ??
          const [];
      return raw
          .map((item) => DetectedApp.fromJson(Map<dynamic, dynamic>.from(item)))
          .toList();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to discover supported device apps.',
        name: 'AppDiscoveryService',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<AiAppHandoffResult> handoffPromptToAiApp(
    String prompt, {
    String? preferredAppId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'handoffPromptToAiApp',
        {'prompt': prompt, 'preferredAppId': ?preferredAppId},
      );
      return AiAppHandoffResult.fromJson(raw ?? const {});
    } catch (error, stackTrace) {
      developer.log(
        'Failed to hand off prompt to an installed AI app.',
        name: 'AppDiscoveryService',
        error: error,
        stackTrace: stackTrace,
      );
      return const AiAppHandoffResult(
        opened: false,
        providerName: '',
        packageName: '',
        copiedToClipboard: false,
        message: 'Could not open an installed AI app from this device.',
      );
    }
  }
}
