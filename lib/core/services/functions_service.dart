
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

class FunctionsService {
  FunctionsService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<T> call<T>(
    String functionName, {
    Map<String, dynamic>? data,
  }) async {
    try {
      final response = await _client.functions.invoke(
        functionName,
        body: data,
      );

      final payload = _toMap(response.data);

      if (response.status < 200 || response.status >= 300) {
        throw FunctionsException.fromPayload(
          payload,
          status: response.status,
        );
      }

      return response.data as T;
    } on FunctionsException {
      rethrow;
    } catch (error) {
      final dynamic exception = error;

      dynamic details;
      dynamic status;

      try {
        details = exception.details;
      } catch (_) {
        details = null;
      }

      try {
        status = exception.status;
      } catch (_) {
        status = null;
      }

      final payload = _toMap(details);

      throw FunctionsException.fromPayload(
        payload,
        status: status is num ? status.toInt() : null,
        fallbackMessage: error.toString(),
      );
    }
  }

  static Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }

    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // The response was not valid JSON.
      }
    }

    return <String, dynamic>{};
  }
}

class FunctionsException implements Exception {
  FunctionsException({
    required this.message,
    this.code,
    this.status,
    this.payload = const {},
  });

  final String message;
  final String? code;
  final int? status;
  final Map<String, dynamic> payload;

  factory FunctionsException.fromPayload(
    Map<String, dynamic> payload, {
    int? status,
    String? fallbackMessage,
  }) {
    final rawCode = payload['error'] ?? payload['code'];
    final rawMessage = payload['message'] ??
        payload['details'] ??
        payload['error_description'];

    return FunctionsException(
      code: rawCode?.toString(),
      message: rawMessage?.toString() ??
          rawCode?.toString() ??
          fallbackMessage ??
          'Server operation failed',
      status: status,
      payload: payload,
    );
  }

  @override
  String toString() => code == null ? message : '$code: $message';
}
