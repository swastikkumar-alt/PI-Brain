import 'dart:developer' as developer;

import 'package:flutter/services.dart';

typedef VoiceTextCallback = void Function(String text);

class VoiceService {
  VoiceService._init() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final VoiceService instance = VoiceService._init();

  static const MethodChannel _channel = MethodChannel('pie_mobile/voice');

  VoiceTextCallback? onPartialTranscript;
  VoiceTextCallback? onFinalTranscript;
  VoiceTextCallback? onError;

  Future<bool> checkPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check microphone permission.',
        name: 'VoiceService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request microphone permission.',
        name: 'VoiceService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> startListening() async {
    await _channel.invokeMethod<void>('startListening');
  }

  Future<void> stopListening() async {
    await _channel.invokeMethod<void>('stopListening');
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _channel.invokeMethod<void>('speak', {'text': text});
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    final text = call.arguments?.toString() ?? '';
    switch (call.method) {
      case 'onPartialTranscript':
        onPartialTranscript?.call(text);
        break;
      case 'onFinalTranscript':
        onFinalTranscript?.call(text);
        break;
      case 'onVoiceError':
        onError?.call(text.isEmpty ? 'Voice recognition failed.' : text);
        break;
    }
  }
}
