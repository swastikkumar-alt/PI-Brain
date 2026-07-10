import '../models/phone_action.dart';

class ManualRecipientFactory {
  const ManualRecipientFactory();

  ContactCandidate? fromCommand(ParsedPhoneCommand command) {
    if (command.type == PhoneActionType.emailMessage &&
        isEmailAddress(command.recipientQuery)) {
      final email = command.recipientQuery.trim().toLowerCase();
      return ContactCandidate(
        id: 'manual_email_$email',
        displayName: email,
        phoneNumber: '',
        normalizedPhoneNumber: '',
        emailAddress: email,
        source: 'manual',
        recipientKind: RecipientKind.manualEmail,
      );
    }

    if (command.type == PhoneActionType.whatsappMessage &&
        isPhoneNumber(command.recipientQuery)) {
      final normalizedPhone = normalizePhone(command.recipientQuery);
      return ContactCandidate(
        id: 'manual_phone_$normalizedPhone',
        displayName: normalizedPhone,
        phoneNumber: command.recipientQuery,
        normalizedPhoneNumber: normalizedPhone,
        source: 'manual',
        recipientKind: RecipientKind.manualPhone,
      );
    }

    return null;
  }

  bool isEmailAddress(String value) {
    return RegExp(
      r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  bool isPhoneNumber(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 8 && RegExp(r'^[+()\-\d\s]+$').hasMatch(value);
  }

  String normalizePhone(String value) {
    final trimmed = value.trim();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (trimmed.startsWith('+')) return '+$digits';
    return digits;
  }
}
