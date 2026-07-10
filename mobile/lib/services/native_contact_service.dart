import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../models/phone_action.dart';

class NativeContactService {
  NativeContactService._init();

  static final NativeContactService instance = NativeContactService._init();

  static const MethodChannel _channel = MethodChannel('pie_mobile/contacts');

  Future<bool> checkPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to check contacts permission.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to request contacts permission.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<List<ContactCandidate>> searchContacts(String query) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('searchContacts', {
        'query': query,
      });
      return (raw ?? [])
          .whereType<Map>()
          .map(
            (item) =>
                ContactCandidate.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((candidate) => candidate.normalizedPhoneNumber.isNotEmpty)
          .toList();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to search contacts.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<List<ContactCandidate>> listPhoneContacts({int limit = 750}) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listPhoneContacts',
        {'limit': limit},
      );
      return (raw ?? [])
          .whereType<Map>()
          .map(
            (item) =>
                ContactCandidate.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((candidate) => candidate.normalizedPhoneNumber.isNotEmpty)
          .toList();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to list phone contacts.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<List<ContactCandidate>> searchEmailContacts(String query) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'searchEmailContacts',
        {'query': query},
      );
      return (raw ?? [])
          .whereType<Map>()
          .map(
            (item) =>
                ContactCandidate.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((candidate) => candidate.emailAddress.isNotEmpty)
          .toList();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to search email contacts.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<List<ContactCandidate>> listEmailContacts({int limit = 750}) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listEmailContacts',
        {'limit': limit},
      );
      return (raw ?? [])
          .whereType<Map>()
          .map(
            (item) =>
                ContactCandidate.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((candidate) => candidate.emailAddress.isNotEmpty)
          .toList();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to list email contacts.',
        name: 'NativeContactService',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }
}
