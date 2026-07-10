import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class OnboardingService {
  OnboardingService._init();

  static final OnboardingService instance = OnboardingService._init();
  static const _storage = FlutterSecureStorage();
  static const _introSeenKey = 'pie_intro_seen_v2';

  Future<bool> hasSeenIntro() async {
    try {
      return await _storage.read(key: _introSeenKey) == 'true';
    } catch (error, stackTrace) {
      developer.log(
        'Failed to read onboarding state.',
        name: 'OnboardingService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> markIntroSeen() async {
    try {
      await _storage.write(key: _introSeenKey, value: 'true');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to persist onboarding state.',
        name: 'OnboardingService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
