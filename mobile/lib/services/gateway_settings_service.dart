import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';

class GatewayRuntimeSettings {
  const GatewayRuntimeSettings({
    required this.gatewayUrl,
    required this.hasCustomUrl,
    required this.hasBearerToken,
  });

  final String gatewayUrl;
  final bool hasCustomUrl;
  final bool hasBearerToken;
}

class GatewaySettingsService {
  GatewaySettingsService._init();

  static final GatewaySettingsService instance = GatewaySettingsService._init();

  static const _gatewayUrlKey = 'gateway_base_url';
  static const _gatewayAccessTokenKey = 'gateway_access_token';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<String> getGatewayBaseUrl() async {
    final stored = await _storage.read(key: _gatewayUrlKey);
    final normalized = _normalizeGatewayUrl(stored);
    return normalized.isEmpty ? AppConfig.gatewayBaseUrl : normalized;
  }

  Future<String> getBearerToken() async {
    final stored = await _storage.read(key: _gatewayAccessTokenKey);
    final token = stored?.trim() ?? '';
    return token.isEmpty ? AppConfig.gatewayBearerToken : token;
  }

  Future<GatewayRuntimeSettings> currentSettings() async {
    final storedUrl = _normalizeGatewayUrl(
      await _storage.read(key: _gatewayUrlKey),
    );
    final storedToken = (await _storage.read(
      key: _gatewayAccessTokenKey,
    ))?.trim();
    return GatewayRuntimeSettings(
      gatewayUrl: storedUrl.isEmpty ? AppConfig.gatewayBaseUrl : storedUrl,
      hasCustomUrl: storedUrl.isNotEmpty,
      hasBearerToken:
          (storedToken != null && storedToken.isNotEmpty) ||
          AppConfig.gatewayBearerToken.isNotEmpty,
    );
  }

  Future<void> save({required String gatewayUrl, String? bearerToken}) async {
    final normalized = _normalizeGatewayUrl(gatewayUrl);
    if (normalized.isEmpty || normalized == AppConfig.gatewayBaseUrl) {
      await _storage.delete(key: _gatewayUrlKey);
    } else {
      await _storage.write(key: _gatewayUrlKey, value: normalized);
    }

    final token = bearerToken?.trim();
    if (token != null && token.isNotEmpty) {
      await _storage.write(key: _gatewayAccessTokenKey, value: token);
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _gatewayUrlKey);
    await _storage.delete(key: _gatewayAccessTokenKey);
  }

  String _normalizeGatewayUrl(String? value) {
    var normalized = value?.trim() ?? '';
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
