import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/entity.dart';
import 'database_service.dart';

class SmsImportResult extends NativeImportResult {
  const SmsImportResult({
    required super.imported,
    required super.skippedDuplicates,
    required super.totalRead,
    super.blockedReason,
    super.nativeCursor,
  });
}

class NativeImportResult {
  const NativeImportResult({
    required this.imported,
    required this.skippedDuplicates,
    required this.totalRead,
    this.blockedReason,
    this.nativeCursor,
  });

  final int imported;
  final int skippedDuplicates;
  final int totalRead;
  final String? blockedReason;
  final String? nativeCursor;

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

  Future<bool> checkSmsManagementCapability() async {
    try {
      return await _channel.invokeMethod<bool>(
            'checkSmsManagementCapability',
          ) ??
          false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check SMS management capability.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestDefaultSmsRole() async {
    try {
      await _channel.invokeMethod('requestDefaultSmsRole');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request default SMS role.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<Map<String, String>> deleteSmsByNativeId(String smsId) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'deleteSmsById',
        {'id': smsId},
      );
      return {
        'status': result?['status']?.toString() ?? 'failed',
        'message': result?['message']?.toString() ?? 'SMS delete failed.',
      };
    } catch (error) {
      return {'status': 'failed', 'message': 'SMS delete failed: $error'};
    }
  }

  Future<bool> checkCallLogPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkCallLogPermission') ??
          false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check call-log permission.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestCallLogPermission() async {
    try {
      await _channel.invokeMethod('requestCallLogPermission');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request call-log permission.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<SmsImportResult> importRecentSms({
    int limit = 500,
    bool queueSync = false,
  }) async {
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
      var newestDate = 0;

      for (final item in rawMessages) {
        final message = Map<String, dynamic>.from(item as Map);
        final content = _smsContent(message);
        if (content.trim().isEmpty) continue;

        final now = DateTime.now().millisecondsSinceEpoch;
        final messageDate = (message['date'] as num?)?.toInt() ?? now;
        if (messageDate > newestDate) newestDate = messageDate;
        final entity = Entity(
          id: 'sms_${message['id'] ?? now}',
          entityType: 'message',
          sourceConnector: 'SMS',
          content: content,
          createdAt: messageDate,
          updatedAt: now,
        );
        final inserted = await DatabaseService.instance.insertEntity(
          entity,
          queueSync: queueSync,
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
        nativeCursor: newestDate == 0 ? null : newestDate.toString(),
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

  Future<NativeImportResult> importRecentCalls({
    int limit = 500,
    bool queueSync = false,
  }) async {
    if (!await checkCallLogPermission()) {
      await requestCallLogPermission();
      return const NativeImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: 'Grant Call Log permission, then run import again.',
      );
    }

    try {
      final rawCalls =
          await _channel.invokeMethod<List<dynamic>>('readRecentCalls', {
            'limit': limit,
          }) ??
          const [];
      var imported = 0;
      var skipped = 0;
      var newestDate = 0;

      for (final item in rawCalls) {
        final call = Map<String, dynamic>.from(item as Map);
        final content = _callLogContent(call);
        if (content.trim().isEmpty) continue;

        final now = DateTime.now().millisecondsSinceEpoch;
        final callDate = (call['date'] as num?)?.toInt() ?? now;
        if (callDate > newestDate) newestDate = callDate;
        final entity = Entity(
          id: 'call_${call['id'] ?? now}',
          entityType: 'call_log',
          sourceConnector: 'CALL_LOG',
          content: content,
          createdAt: callDate,
          updatedAt: now,
        );
        final inserted = await DatabaseService.instance.insertEntity(
          entity,
          queueSync: queueSync,
        );
        if (inserted) {
          imported += 1;
        } else {
          skipped += 1;
        }
      }

      return NativeImportResult(
        imported: imported,
        skippedDuplicates: skipped,
        totalRead: rawCalls.length,
        nativeCursor: newestDate == 0 ? null : newestDate.toString(),
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to import call logs.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: 'Call log import failed: $error',
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

  Future<NativeImportResult> importHealthSummary({
    int days = 30,
    bool queueSync = false,
  }) async {
    try {
      final rawRows =
          await _channel.invokeMethod<List<dynamic>>('readHealthSummary', {
            'days': days,
          }) ??
          const [];
      var imported = 0;
      var skipped = 0;

      for (final item in rawRows) {
        final row = Map<String, dynamic>.from(item as Map);
        final content = _healthContent(row);
        if (content.trim().isEmpty) continue;

        final now = DateTime.now().millisecondsSinceEpoch;
        final entity = Entity(
          id: 'health_${row['date'] ?? now}',
          entityType: 'health_summary',
          sourceConnector: 'HEALTH',
          content: content,
          createdAt: (row['startAt'] as num?)?.toInt() ?? now,
          updatedAt: now,
        );
        final inserted = await DatabaseService.instance.insertEntity(
          entity,
          queueSync: queueSync,
        );
        if (inserted) {
          imported += 1;
        } else {
          skipped += 1;
        }
      }

      return NativeImportResult(
        imported: imported,
        skippedDuplicates: skipped,
        totalRead: rawRows.length,
        nativeCursor: rawRows.isEmpty ? null : rawRows.length.toString(),
      );
    } on PlatformException catch (error) {
      return NativeImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: error.message ?? 'Health Connect import is blocked.',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to import Health Connect records.',
        name: 'NativeDatasourceService',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeImportResult(
        imported: 0,
        skippedDuplicates: 0,
        totalRead: 0,
        blockedReason: 'Health Connect import failed: $error',
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

  String _callLogContent(Map<String, dynamic> call) {
    final number = call['number']?.toString().trim() ?? 'Unknown';
    final name = call['name']?.toString().trim() ?? '';
    final type = call['typeLabel']?.toString().trim() ?? 'Unknown';
    final date = call['date']?.toString() ?? '';
    final duration = call['durationSeconds']?.toString() ?? '0';
    final cachedName = name.isEmpty ? '' : '\nName: $name';
    return 'Call Log\nType: $type\nNumber: $number$cachedName\nDate: $date\nDuration seconds: $duration';
  }

  String _healthContent(Map<String, dynamic> row) {
    final date = row['date']?.toString() ?? '';
    final steps = row['steps']?.toString() ?? '0';
    final sleepMinutes = row['sleepMinutes']?.toString() ?? '0';
    final sleepStart = row['sleepStart']?.toString() ?? '';
    final sleepEnd = row['sleepEnd']?.toString() ?? '';
    return 'Health Summary\nDate: $date\nSteps: $steps\nSleep minutes: $sleepMinutes\nSleep start: $sleepStart\nSleep end: $sleepEnd';
  }
}
