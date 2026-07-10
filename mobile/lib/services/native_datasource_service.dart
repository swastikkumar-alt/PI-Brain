import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/entity.dart';
import 'database_service.dart';

class SmsImportResult {
  const SmsImportResult({
    required this.imported,
    required this.skippedDuplicates,
    required this.totalRead,
    this.blockedReason,
  });

  final int imported;
  final int skippedDuplicates;
  final int totalRead;
  final String? blockedReason;

  bool get isBlocked => blockedReason != null && blockedReason!.isNotEmpty;
}

class HealthConnectState {
  const HealthConnectState({required this.available, required this.message});

  final bool available;
  final String message;
}

class NativeDatasourceService {
  NativeDatasourceService._init();

  static final NativeDatasourceService instance =
      NativeDatasourceService._init();

  static const MethodChannel _channel = MethodChannel(
    'pie_mobile/native_datasources',
  );

  Future<bool> checkSmsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkSmsPermission') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check SMS permission.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestSmsPermission() async {
    try {
      await _channel.invokeMethod('requestSmsPermission');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request SMS permission.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<SmsImportResult> importRecentSms({int limit = 500}) async {
    if (!await checkSmsPermission()) {
      await requestSmsPermission();
      return const SmsImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: 'Grant SMS permission, then run import again.',
      );
    }

    try {
      final rawMessages =
          await _channel.invokeMethod<List<dynamic>>('readRecentSms', {
            'limit': limit,
          }) ??
          const [];
      var imported = 0;
      var skipped = 0;

      for (final item in rawMessages) {
        final message = Map<String, dynamic>.from(item as Map);
        final content = _smsContent(message);
        if (content.trim().isEmpty) continue;

        final now = DateTime.now().millisecondsSinceEpoch;
        final entity = Entity(
          id: 'sms_${message['id'] ?? now}',
          entityType: 'message',
          sourceConnector: 'SMS',
          content: content,
          createdAt: (message['date'] as num?)?.toInt() ?? now,
          updatedAt: now,
        );
        final inserted = await DatabaseService.instance.insertEntity(
          entity,
          queueSync: true,
        );
        if (inserted) {
          imported += 1;
        } else {
          skipped += 1;
        }
      }

      return SmsImportResult(
        imported: imported,
        skippedDuplicates: skipped,
        totalRead: rawMessages.length,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to import SMS messages.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return SmsImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: 'SMS import failed: $error',
      );
    }
  }

  Future<HealthConnectState> checkHealthConnect() async {
    try {
      final state = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'checkHealthConnect',
      );
      return HealthConnectState(
        available: state?['available'] == true,
        message:
            state?['message']?.toString() ??
            'Health Connect status is unavailable.',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check Health Connect.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return const HealthConnectState(
        available: false,
        message: 'Health Connect check failed.',
      );
    }
  }

  Future<void> openHealthConnect() async {
    try {
      await _channel.invokeMethod('openHealthConnect');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to open Health Connect.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String _smsContent(Map<String, dynamic> sms) {
    final direction = sms['type']?.toString() == '2' ? 'Sent' : 'Received';
    final address = sms['address']?.toString().trim() ?? 'Unknown';
    final body = sms['body']?.toString().trim() ?? '';
    final date = sms['date']?.toString() ?? '';
    return '$direction SMS\nFrom/To: $address\nDate: $date\n\n$body';
  }
}
