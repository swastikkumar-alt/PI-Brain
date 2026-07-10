import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/phone_action.dart';
import 'phone_connector.dart';

class WhatsAppConnectorService implements PhoneConnector {
  WhatsAppConnectorService._init() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final WhatsAppConnectorService instance =
      WhatsAppConnectorService._init();

  static const MethodChannel _channel = MethodChannel('pie_mobile/connectors');

  final Map<String, Completer<PhoneActionExecutionResult>> _pending = {};

  @override
  String get id => 'whatsapp';

  @override
  String get displayName => 'WhatsApp';

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isWhatsAppInstalled') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check WhatsApp availability.',
        name: 'WhatsAppConnectorService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<PhoneActionExecutionResult> execute(PhoneActionPlan plan) async {
    final contact = plan.contact;
    if (contact == null) {
      return const PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: 'No verified contact was selected.',
      );
    }

    final completer = Completer<PhoneActionExecutionResult>();
    _pending[plan.id] = completer;

    try {
      final started = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('sendWhatsAppMessage', {
            'actionId': plan.id,
            'recipientName': contact.displayName,
            'phoneNumber': contact.normalizedPhoneNumber,
            'message': plan.outgoingText,
            'unlockPolicy': plan.unlockPolicy.name,
          });

      if (started?['status']?.toString() != 'started') {
        _pending.remove(plan.id);
        return PhoneActionExecutionResult(
          status: PhoneActionStatus.failed,
          message:
              started?['message']?.toString() ??
              'WhatsApp action did not start.',
        );
      }

      return completer.future.timeout(
        _automationTimeout(plan.unlockPolicy),
        onTimeout: () {
          _pending.remove(plan.id);
          return const PhoneActionExecutionResult(
            status: PhoneActionStatus.failed,
            message:
                'No WhatsApp automation result was received. Check PIE Settings > Capture Service, unlock WhatsApp if app lock appears, then retry.',
          );
        },
      );
    } catch (error, stackTrace) {
      _pending.remove(plan.id);
      developer.log(
        'Failed to execute WhatsApp action.',
        name: 'WhatsAppConnectorService',
        error: error,
        stackTrace: stackTrace,
      );
      return PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: 'WhatsApp execution failed: $error',
      );
    }
  }

  Duration _automationTimeout(AppUnlockPolicy policy) {
    return switch (policy) {
      AppUnlockPolicy.sessionUnlock => const Duration(seconds: 610),
      AppUnlockPolicy.unlockEachTime => const Duration(seconds: 190),
      AppUnlockPolicy.skipLockedApps => const Duration(seconds: 35),
    };
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onConnectorEvent') return;

    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final actionId = args['actionId']?.toString();
    if (actionId == null || actionId.isEmpty) return;

    final completer = _pending.remove(actionId);
    if (completer == null || completer.isCompleted) return;

    final statusText = args['status']?.toString() ?? 'failed';
    final status = statusText == 'executed'
        ? PhoneActionStatus.executed
        : PhoneActionStatus.failed;
    completer.complete(
      PhoneActionExecutionResult(
        status: status,
        message: args['message']?.toString() ?? statusText,
        rawDetails: args,
      ),
    );
  }
}
