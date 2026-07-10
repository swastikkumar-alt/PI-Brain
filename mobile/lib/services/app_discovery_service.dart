import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/detected_app.dart';

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
}
