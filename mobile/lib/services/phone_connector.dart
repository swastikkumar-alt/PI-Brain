import '../models/phone_action.dart';

abstract class PhoneConnector {
  String get id;
  String get displayName;

  Future<bool> isAvailable();

  Future<PhoneActionExecutionResult> execute(PhoneActionPlan plan);
}
