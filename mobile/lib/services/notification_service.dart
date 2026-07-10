import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import '../models/entity.dart';
import 'database_service.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._init();
  final MethodChannel _channel = const MethodChannel(
    'pie_mobile/notifications',
  );

  NotificationService._init() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  void initialize() {
    // Simply initializing the singleton sets up the method channel listener.
  }

  Future<bool> checkPermission() async {
    try {
      final bool hasPermission = await _channel.invokeMethod('checkPermission');
      return hasPermission;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check notification listener permission.',
        name: 'NotificationService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request notification listener permission.',
        name: 'NotificationService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> isGmailInstalled() async {
    return _isPackageInstalled('isGmailInstalled', 'Gmail');
  }

  Future<bool> isWhatsAppInstalled() async {
    return _isPackageInstalled('isWhatsAppInstalled', 'WhatsApp');
  }

  Future<bool> _isPackageInstalled(String method, String appName) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check $appName availability.',
        name: 'NotificationService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onNotification') {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final String packageName = args['packageName']?.toString() ?? '';
      final String title = args['title']?.toString().trim() ?? '';
      final String text = args['text']?.toString().trim() ?? '';

      if (packageName.isEmpty || text.isEmpty) return;

      String sourceType = 'NOTIFICATION';
      String datasourceId = 'notifications';
      if (packageName == 'com.whatsapp' || packageName == 'com.whatsapp.w4b') {
        sourceType = 'CHAT';
        datasourceId = 'whatsapp_context';
      } else if (packageName == 'com.google.android.gm') {
        sourceType = 'GMAIL';
        datasourceId = 'gmail_notifications';
      } else if (_looksLikePaymentNotification(title, text)) {
        sourceType = 'PAYMENT';
        datasourceId = 'notifications';
      } else {
        return;
      }

      final isEnabled = await DatabaseService.instance.isDatasourceEnabled(
        datasourceId,
      );
      if (!isEnabled) return;
      if (_isLowValueWhatsAppSummary(packageName, title, text)) return;

      final docId = 'notif_${DateTime.now().millisecondsSinceEpoch}';

      final content = 'Notification from ${_canonicalTitle(title)}: $text';

      final docEntity = Entity(
        id: docId,
        entityType: 'document',
        sourceConnector: sourceType,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      await DatabaseService.instance.insertEntity(docEntity, queueSync: true);
    }
  }

  bool _isLowValueWhatsAppSummary(
    String packageName,
    String title,
    String text,
  ) {
    if (packageName != 'com.whatsapp' && packageName != 'com.whatsapp.w4b') {
      return false;
    }
    final normalizedTitle = title.trim().toLowerCase();
    final normalizedText = text.trim().toLowerCase();
    return normalizedTitle == 'whatsapp' &&
        RegExp(
          r'^\d+\s+messages?\s+from\s+\d+\s+chats?$',
        ).hasMatch(normalizedText);
  }

  String _canonicalTitle(String title) {
    return title.trim().replaceFirst(
      RegExp(r'\s+\(\d+\s+messages?\)\s*$', caseSensitive: false),
      '',
    );
  }

  bool _looksLikePaymentNotification(String title, String text) {
    final combined = '$title $text'.toLowerCase();
    final hasAmount = RegExp(
      '(?:\\u20B9|rs\\.?|inr)\\s*[0-9][0-9,]*(?:\\.\\d{1,2})?|'
      '[0-9][0-9,]*(?:\\.\\d{1,2})?\\s*(?:\\u20B9|rs\\.?|inr)',
      caseSensitive: false,
    ).hasMatch(combined);
    if (!hasAmount) return false;

    final hasDebitIntent = RegExp(
      r'\b(?:debited|debit|spent|paid|payment|purchase|withdrawn|deducted|sent|transferred|upi|card|pos)\b',
      caseSensitive: false,
    ).hasMatch(combined);
    if (!hasDebitIntent) return false;

    return !RegExp(
      r'\b(?:otp|failed|declined|unsuccessful|pending|credited|refund|cashback|reversal)\b',
      caseSensitive: false,
    ).hasMatch(combined);
  }
}
