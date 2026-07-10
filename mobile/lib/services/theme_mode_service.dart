import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemeModeService extends ChangeNotifier {
  ThemeModeService._init();

  static final ThemeModeService instance = ThemeModeService._init();
  static const _storage = FlutterSecureStorage();
  static const _themeModeKey = 'pie_theme_mode';

  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _themeModeKey);
      _themeMode = _parse(raw);
    } catch (error, stackTrace) {
      developer.log(
        'Failed to load theme mode.',
        name: 'ThemeModeService',
        error: error,
        stackTrace: stackTrace,
      );
      _themeMode = ThemeMode.dark;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      await _storage.write(key: _themeModeKey, value: mode.name);
    } catch (error, stackTrace) {
      developer.log(
        'Failed to persist theme mode.',
        name: 'ThemeModeService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  ThemeMode _parse(String? raw) {
    return switch (raw) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }
}
