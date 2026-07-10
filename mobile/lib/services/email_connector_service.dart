import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/phone_action.dart';
import 'phone_connector.dart';

class EmailConnectorService implements PhoneConnector {
  EmailConnectorService._init();

  static final EmailConnectorService instance = EmailConnectorService._init();

  static const MethodChannel _channel = MethodChannel('pie_mobile/connectors');

  @override
  String get id => 'email';

  @override
  String get displayName => 'Email';

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isEmailAvailable') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check email availability.',
        name: 'EmailConnectorService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<PhoneActionExecutionResult> execute(PhoneActionPlan plan) async {
    final recipient = plan.contact;
    final emailAddress = recipient?.emailAddress ?? '';
    if (emailAddress.trim().isEmpty) {
      return const PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: 'No verified email address was selected.',
      );
    }

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('composeEmail', {
            'actionId': plan.id,
            'emailAddress': emailAddress,
            'subject': plan.emailSubject ?? 'Update',
            'body': plan.outgoingText,
            'attachmentPaths': plan.emailAttachmentPaths,
          });
      final status = result?['status']?.toString();
      return PhoneActionExecutionResult(
        status: status == 'started'
            ? PhoneActionStatus.executed
            : PhoneActionStatus.failed,
        message: result?['message']?.toString() ?? 'Email compose opened.',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to compose email.',
        name: 'EmailConnectorService',
        error: error,
        stackTrace: stackTrace,
      );
      return PhoneActionExecutionResult(
        status: PhoneActionStatus.failed,
        message: 'Email compose failed: $error',
      );
    }
  }
}
