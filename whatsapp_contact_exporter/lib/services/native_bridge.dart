import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/export_models.dart';
import 'phone_normalizer.dart';

class NativeBridge {
  static const _contacts = MethodChannel('wa_group_extractor/contacts');
  static const _accessibility = MethodChannel(
    'wa_group_extractor/accessibility',
  );
  static const _files = MethodChannel('wa_group_extractor/files');
  static const _network = MethodChannel('wa_group_extractor/network');

  Future<bool> contactsPermissionGranted() async {
    return await _contacts.invokeMethod<bool>('contactsPermissionGranted') ??
        false;
  }

  Future<bool> requestContactsPermission() async {
    return await _contacts.invokeMethod<bool>('requestContactsPermission') ??
        false;
  }

  Future<List<ExportedContact>> importLocalContacts() async {
    final raw = await _contacts.invokeMethod<List<dynamic>>(
      'importLocalContacts',
    );
    final now = DateTime.now();
    return (raw ?? const [])
        .whereType<Map>()
        .map((item) {
          final map = item.map((key, value) => MapEntry('$key', value));
          final phone = '${map['phone'] ?? ''}';
          return ExportedContact(
            id: '${map['id'] ?? ''}',
            name: '${map['name'] ?? ''}',
            phone: phone,
            normalizedPhone: '${map['normalized_phone'] ?? ''}'.ifEmpty(
              () => PhoneNormalizer.normalize(phone),
            ),
            email: '${map['email'] ?? ''}',
            source: '${map['source'] ?? 'android_contacts'}',
            tags: const ['android_contacts'],
            createdAt: now,
          );
        })
        .where(
          (contact) =>
              contact.name.isNotEmpty ||
              contact.phone.isNotEmpty ||
              contact.email.isNotEmpty,
        )
        .toList();
  }

  Future<bool> accessibilityEnabled() async {
    return await _accessibility.invokeMethod<bool>('accessibilityEnabled') ??
        false;
  }

  Future<void> openAccessibilitySettings() async {
    await _accessibility.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<void> openWhatsApp() async {
    await _accessibility.invokeMethod<void>('openWhatsApp');
  }

  Future<CaptureBatch?> latestCapture() async {
    final json = await _accessibility.invokeMethod<String>('latestCapture');
    if (json == null || json.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return CaptureBatch.fromJson(decoded);
  }

  Future<void> clearLatestCapture() async {
    await _accessibility.invokeMethod<void>('clearLatestCapture');
  }

  Future<String> copyToDownloads({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async {
    final result = await _files.invokeMethod<String>('copyToDownloads', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'mimeType': mimeType,
    });
    return result ?? sourcePath;
  }

  Future<WebNetworkCheck> checkWhatsAppWeb() async {
    final raw = await _network.invokeMethod<Map<dynamic, dynamic>>(
      'checkWhatsAppWeb',
    );
    return WebNetworkCheck.fromMap(raw ?? const {});
  }
}

class WebNetworkCheck {
  const WebNetworkCheck({
    required this.host,
    required this.dnsOk,
    required this.httpsOk,
    required this.addresses,
    required this.statusCode,
    required this.error,
  });

  final String host;
  final bool dnsOk;
  final bool httpsOk;
  final List<String> addresses;
  final int statusCode;
  final String error;

  bool get reachable => dnsOk && httpsOk;

  String get summary {
    if (reachable) {
      final addressText = addresses.isEmpty
          ? host
          : addresses.take(2).join(', ');
      return 'WhatsApp Web network is reachable ($addressText).';
    }
    if (!dnsOk) {
      return 'DNS cannot resolve $host. Check Private DNS, VPN, ad blocker, or network.';
    }
    return 'DNS works but HTTPS to $host failed. $error'.trim();
  }

  factory WebNetworkCheck.fromMap(Map<dynamic, dynamic> map) {
    final rawAddresses = map['addresses'];
    return WebNetworkCheck(
      host: '${map['host'] ?? 'web.whatsapp.com'}',
      dnsOk: map['dns_ok'] == true,
      httpsOk: map['https_ok'] == true,
      addresses: rawAddresses is List
          ? rawAddresses.map((address) => '$address').toList()
          : const [],
      statusCode: int.tryParse('${map['status_code'] ?? -1}') ?? -1,
      error: '${map['error'] ?? ''}',
    );
  }
}

extension _StringFallback on String {
  String ifEmpty(String Function() fallback) => isEmpty ? fallback() : this;
}
