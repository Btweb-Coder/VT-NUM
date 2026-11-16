
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tnum_activation.dart';

class TnumRepository {
  TnumRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _invoke(
    String name, [
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    FunctionResponse response;

    try {
      response = await _client.functions
          .invoke(name, body: body)
          .timeout(timeout);
    } catch (error) {
      final dynamic typed = error;

      dynamic details;
      try {
        details = typed.details;
      } catch (_) {
        details = null;
      }

      final status = () {
        try {
          return (typed.status as num?)?.toInt();
        } catch (_) {
          return null;
        }
      }();

      // TEMPORARY DEBUG LOGS
      debugPrint('[T-NUM DEBUG] Exception type: ${error.runtimeType}');
      debugPrint('[T-NUM DEBUG] Status: $status');
      debugPrint('[T-NUM DEBUG] Details type: ${details.runtimeType}');
      debugPrint('[T-NUM DEBUG] Details: $details');

      final payload = details is Map
          ? Map<String, dynamic>.from(details)
          : details is String
              ? _decodeError(details)
              : <String, dynamic>{};

      final code = error is TimeoutException
          ? 'NETWORK_TIMEOUT'
          : status == 0
              ? 'NETWORK_CONNECTION'
              : status != null && status >= 500
                  ? 'PROVIDER_TEMPORARILY_UNAVAILABLE'
                  : '${payload['error'] ?? 'TNUM_REQUEST_FAILED'}';

      debugPrint(
        '[T-NUM] $name failed: $code; '
        'correlation_id=${payload['correlation_id'] ?? 'unavailable'}',
      );

      throw TnumRepositoryException(code, payload: payload);
    }

    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      final error = data is Map ? data['error'] : null;

      final payload = data is Map
          ? Map<String, dynamic>.from(data)
          : const <String, dynamic>{};

      final code = '${error ?? 'TNUM_REQUEST_FAILED'}';

      debugPrint(
        '[T-NUM] $name failed: $code; '
        'correlation_id=${payload['correlation_id'] ?? 'unavailable'}',
      );

      throw TnumRepositoryException(code, payload: payload);
    }

    if (response.data is! Map) {
      throw const TnumRepositoryException('INVALID_RESPONSE');
    }

    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> loadCatalog() async {
    await _invoke('tnum-bootstrap-account');
    return _invoke('tnum-get-activation-catalog');
  }

  Future<Map<String, dynamic>> refreshCountry(int code) async {
    await _invoke('tnum-refresh-activation-catalog', {
      'country_code': code,
    });
    return _invoke('tnum-get-activation-catalog');
  }

  Future<TnumQuote> quote(String service, int country) async {
    final result = await _invoke('tnum-get-activation-quote', {
      'service_slug': service,
      'country_code': country,
    });

    return TnumQuote.fromMap(
      Map<String, dynamic>.from(result['quote'] as Map),
    );
  }

  Future<Map<String, dynamic>> requestActivation({
    required String service,
    required int country,
    required String idempotencyKey,
    required String quoteId,
  }) =>
      _invoke(
        'tnum-request-activation',
        {
          'service_slug': service,
          'country_code': country,
          'idempotency_key': idempotencyKey,
          'quote_id': quoteId,
        },
        const Duration(seconds: 45),
      );

  Future<List<Map<String, dynamic>>> activations({
    bool history = false,
  }) async {
    final result = await _invoke(
      history
          ? 'tnum-get-activation-history'
          : 'tnum-get-current-activations',
    );

    return (result['activations'] as List? ?? [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<Map<String, dynamic>> details(
    String id, {
    bool refreshProvider = true,
  }) async {
    final result = await _invoke('tnum-get-activation-details', {
      'id': id,
      'refresh_provider': refreshProvider,
    });

    final activation = Map<String, dynamic>.from(
      result['activation'] as Map,
    );

    activation['_provider_state'] = result['provider_state'];
    activation['_provider_refresh_error'] =
        result['provider_refresh_error'] == true;

    return activation;
  }

  RealtimeChannel watchActivation(
    String activationId, {
    required void Function() onChange,
    required void Function(bool connected) onConnection,
  }) =>
      _client
          .channel('tnum-activation-$activationId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'tnum_activations',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: activationId,
            ),
            callback: (_) => onChange(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'tnum_activation_sms',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'activation_id',
              value: activationId,
            ),
            callback: (_) => onChange(),
          )
          .subscribe((status, _) {
            onConnection(
              status == RealtimeSubscribeStatus.subscribed,
            );
          });

  Future<void> removeActivationWatch(RealtimeChannel channel) =>
      _client.removeChannel(channel);

  Future<void> nextSms(String id) async =>
      _invoke(
        'tnum-request-next-sms',
        {'id': id},
        const Duration(seconds: 40),
      );

  Future<void> complete(String id) async => _invoke(
        'tnum-complete-activation',
        {'id': id},
        const Duration(seconds: 40),
      );

  Future<Map<String, dynamic>> poll() =>
      _invoke('tnum-poll-activation-updates');

  Future<Map<String, dynamic>> wallet() async {
    final result = await _invoke('tnum-get-wallet');

    return Map<String, dynamic>.from(
      result['wallet'] as Map? ?? const {},
    );
  }
}

Map<String, dynamic> _decodeError(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map
        ? Map<String, dynamic>.from(value)
        : const {};
  } catch (_) {
    return const {};
  }
}

class TnumRepositoryException implements Exception {
  const TnumRepositoryException(
    this.code, {
    this.payload = const {},
  });

  final String code;
  final Map<String, dynamic> payload;

  @override
  String toString() => code;
}
