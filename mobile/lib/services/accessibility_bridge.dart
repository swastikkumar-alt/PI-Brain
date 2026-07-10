import 'dart:developer' as developer;

import 'package:flutter/services.dart';

class AccessibilityBridge {
  AccessibilityBridge._init();

  static final AccessibilityBridge instance = AccessibilityBridge._init();

  static const MethodChannel _channel = MethodChannel(
    'pie_mobile/accessibility',
  );

  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check Accessibility service state.',
        name: 'AccessibilityBridge',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to open Accessibility settings.',
        name: 'AccessibilityBridge',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
