class PhoneNormalizer {
  const PhoneNormalizer._();

  static String normalize(String? input) {
    if (input == null) {
      return '';
    }
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final startsWithPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      return '';
    }

    if (startsWithPlus) {
      return '+$digits';
    }
    if (digits.startsWith('00') && digits.length > 8) {
      return '+${digits.substring(2)}';
    }
    return digits;
  }

  static bool looksLikePhone(String input) {
    return normalize(input).isNotEmpty;
  }
}
