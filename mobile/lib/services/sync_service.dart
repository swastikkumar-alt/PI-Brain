import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'app_config.dart';
import 'database_service.dart';
import 'gateway_settings_service.dart';
import '../models/sync_event.dart';

class SyncService {
  static const _keyPairStorageKey = 'pie_sync_p256_key_pair_v1';
  static const _protocolVersion = 'pie-sync-v1';

  final _storage = const FlutterSecureStorage();
  final _gatewaySettings = GatewaySettingsService.instance;
  final DatabaseService _db = DatabaseService.instance;
  final Ecdh _ecdh = Ecdh.p256(length: 32);
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final AesGcm _aesGcm = AesGcm.with256bits();

  String gatewayUrl = AppConfig.gatewayBaseUrl;
  bool isOnline = true;
  final String _deviceId = AppConfig.deviceId;

  String _base64UrlNoPadding(List<int> bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Uint8List _decodeBase64Url(String value) {
    final padded = value.padRight(
      value.length + (4 - value.length % 4) % 4,
      '=',
    );
    return Uint8List.fromList(base64Url.decode(padded));
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await _gatewaySettings.getBearerToken();

    return {
      if (json) 'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<String> _activeGatewayUrl() async {
    if (gatewayUrl != AppConfig.gatewayBaseUrl) return gatewayUrl;
    return _gatewaySettings.getGatewayBaseUrl();
  }

  Future<EcKeyPairData> _getOrCreateIdentityKeyPair() async {
    final stored = await _storage.read(key: _keyPairStorageKey);
    if (stored != null) {
      try {
        final data = jsonDecode(stored) as Map<String, dynamic>;
        return EcKeyPairData(
          d: _decodeBase64Url(data['d'].toString()),
          x: _decodeBase64Url(data['x'].toString()),
          y: _decodeBase64Url(data['y'].toString()),
          type: KeyPairType.p256,
        );
      } catch (error, stackTrace) {
        developer.log(
          'Stored sync key pair was unreadable; rotating it.',
          name: 'SyncService',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final keyPair = await _ecdh.newKeyPair();
    final keyData = await keyPair.extract();
    await _storage.write(
      key: _keyPairStorageKey,
      value: jsonEncode({
        'kty': 'EC',
        'crv': 'P-256',
        'd': _base64UrlNoPadding(keyData.d),
        'x': _base64UrlNoPadding(keyData.x),
        'y': _base64UrlNoPadding(keyData.y),
      }),
    );
    await _storage.delete(key: 'client_public_ecdh');
    await _storage.delete(key: 'client_private_ecdh');

    return keyData;
  }

  Map<String, String> _publicKeyToJwk(EcPublicKey publicKey) {
    return {
      'kty': 'EC',
      'crv': 'P-256',
      'alg': 'ECDH-ES+A256GCM',
      'x': _base64UrlNoPadding(publicKey.x),
      'y': _base64UrlNoPadding(publicKey.y),
    };
  }

  EcPublicKey _parsePeerPublicKey(dynamic value) {
    dynamic keyMaterial = value;
    if (keyMaterial is String) {
      final trimmed = keyMaterial.trim();
      if (trimmed.startsWith('{')) {
        keyMaterial = jsonDecode(trimmed) as Map<String, dynamic>;
      } else {
        final bytes = _decodeBase64Url(trimmed);
        if (bytes.length == 65 && bytes.first == 0x04) {
          return EcPublicKey(
            x: bytes.sublist(1, 33),
            y: bytes.sublist(33, 65),
            type: KeyPairType.p256,
          );
        }
        return EcPublicKey.parseDer(bytes, type: KeyPairType.p256);
      }
    }

    if (keyMaterial is Map) {
      final crv = keyMaterial['crv']?.toString();
      final x = keyMaterial['x']?.toString();
      final y = keyMaterial['y']?.toString();
      if (crv != 'P-256' || x == null || y == null) {
        throw FormatException('Unsupported peer ECDH public key format');
      }

      return EcPublicKey(
        x: _decodeBase64Url(x),
        y: _decodeBase64Url(y),
        type: KeyPairType.p256,
      );
    }

    throw FormatException('Unsupported peer ECDH public key type');
  }

  Future<String> getPublicECDHKey() async {
    final keyPair = await _getOrCreateIdentityKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return jsonEncode(_publicKeyToJwk(publicKey));
  }

  Future<Map<String, dynamic>> wrapSyncEvent(
    SyncEvent event,
    List<Map<String, dynamic>> peerDevices,
  ) async {
    final eventPayload = event.toJson();
    final plaintext = utf8.encode(jsonEncode(eventPayload));
    final contentKey = await _aesGcm.newSecretKey();
    final contentKeyBytes = await contentKey.extractBytes();
    final aad = utf8.encode('$_protocolVersion|$_deviceId|${event.eventId}');

    final payloadBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: contentKey,
      nonce: _aesGcm.newNonce(),
      aad: aad,
    );

    Map<String, dynamic> wrappedKeysMap = {};
    for (final peer in peerDevices) {
      final peerDeviceId = peer['device_id']?.toString();
      final peerPublicKeyMaterial = peer['public_ecdh_key'];
      if (peerDeviceId == null || peerPublicKeyMaterial == null) {
        continue;
      }

      final peerPublicKey = _parsePeerPublicKey(peerPublicKeyMaterial);
      final ephemeralKeyPair = await _ecdh.newKeyPair();
      final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
      final sharedSecret = await _ecdh.sharedSecretKey(
        keyPair: ephemeralKeyPair,
        remotePublicKey: peerPublicKey,
      );
      final salt = _aesGcm.newNonce();
      final keyEncryptionKey = await _hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: salt,
      );
      final keyWrapAad = utf8.encode(
        '$_protocolVersion|$_deviceId|$peerDeviceId|${event.eventId}|key-wrap',
      );
      final wrappedKeyBox = await _aesGcm.encrypt(
        contentKeyBytes,
        secretKey: keyEncryptionKey,
        nonce: _aesGcm.newNonce(),
        aad: keyWrapAad,
      );

      wrappedKeysMap[peerDeviceId] = {
        'alg': 'P-256-ECDH-HKDF-SHA256-A256GCMKW',
        'ephemeral_public_key': _publicKeyToJwk(ephemeralPublicKey),
        'salt': _base64UrlNoPadding(salt),
        'nonce': _base64UrlNoPadding(wrappedKeyBox.nonce),
        'ciphertext': _base64UrlNoPadding(wrappedKeyBox.cipherText),
        'tag': _base64UrlNoPadding(wrappedKeyBox.mac.bytes),
        'aad': _base64UrlNoPadding(keyWrapAad),
      };
    }

    if (wrappedKeysMap.isEmpty) {
      throw StateError('No valid peer public keys were available for sync.');
    }

    return {
      'protocol': _protocolVersion,
      'alg': 'A256GCM',
      'event_id': event.eventId,
      'sender_device_id': _deviceId,
      'sender_public_key': jsonDecode(await getPublicECDHKey()),
      'nonce': _base64UrlNoPadding(payloadBox.nonce),
      'ciphertext': _base64UrlNoPadding(payloadBox.cipherText),
      'tag': _base64UrlNoPadding(payloadBox.mac.bytes),
      'aad': _base64UrlNoPadding(aad),
      'wrapped_keys': wrappedKeysMap,
    };
  }

  // --- Secure Synchronization Push ---
  Future<bool> synchronize() async {
    if (!isOnline) {
      return false;
    }

    try {
      // 1. Fetch pending events from local CRDT ledger
      final pendingEvents = await _db.getPendingSyncEvents();
      if (pendingEvents.isEmpty) return true;

      // 2. Retrieve public keys of peer devices registered to user
      final activeGatewayUrl = await _activeGatewayUrl();
      final peerKeysResponse = await http
          .get(
            Uri.parse('$activeGatewayUrl/keys/peers'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 1));

      List<Map<String, dynamic>> peerDevices = [];
      if (peerKeysResponse.statusCode == 200) {
        final data = jsonDecode(peerKeysResponse.body) as List;
        peerDevices = data
            .map(
              (item) => {
                'device_id': item['device_id'].toString(),
                'public_ecdh_key': item['public_ecdh_key'],
              },
            )
            .toList();
      } else {
        return false;
      }

      if (peerDevices.isEmpty) return false;

      // 3. Wrap each event inside the zero-knowledge payload
      List<Map<String, dynamic>> wrappedEvents = [];
      for (var event in pendingEvents) {
        final wrapped = await wrapSyncEvent(event, peerDevices);
        wrappedEvents.add(wrapped);
      }

      // 4. Post sync payload packet to gateway API endpoint
      final syncPacket = {
        'device_id': _deviceId,
        'public_ecdh_key': jsonDecode(await getPublicECDHKey()),
        'events': wrappedEvents,
      };

      final pushResponse = await http
          .post(
            Uri.parse('$activeGatewayUrl/sync/push'),
            headers: await _headers(json: true),
            body: jsonEncode(syncPacket),
          )
          .timeout(const Duration(seconds: 1));

      if (pushResponse.statusCode == 200) {
        // Update local sync status to SYNCED
        final db = await _db.database;
        for (var event in pendingEvents) {
          await db.update(
            'sync_events',
            {'status': 'SYNCED'},
            where: 'event_id = ?',
            whereArgs: [event.eventId],
          );
        }
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      developer.log(
        'Synchronization failed.',
        name: 'SyncService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
