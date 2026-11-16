import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/functions_service.dart';

class TopUpIntent {
  const TopUpIntent({
    required this.id,
    required this.status,
    required this.gateway,
    required this.amount,
    required this.currency,
    required this.providerAmount,
    required this.providerCurrency,
    required this.fee,
    this.checkoutUrl,
    this.failureCode,
  });
  final String id;
  final String status;
  final String gateway;
  final int amount;
  final String currency;
  final int providerAmount;
  final String providerCurrency;
  final double fee;
  final String? checkoutUrl;
  final String? failureCode;
}


class TopUpLimits {
  const TopUpLimits({
    required this.minimum,
    required this.maximum,
    required this.feePercent,
  });

  final double minimum;
  final double maximum;
  final double feePercent;
}


class TopUpRepository {
  TopUpRepository({FunctionsService? functions, SupabaseClient? client})
    : _functions = functions ?? FunctionsService(),
      _client = client ?? Supabase.instance.client;
  final FunctionsService _functions;
  final SupabaseClient _client;

  

Future<TopUpLimits> loadLimits() async {
  final row = await _client
      .from('payment_fee_config')
      .select('min_topup_amount, max_topup_amount, fee_percent')
      .eq('id', true)
      .single();

  final minimum = (row['min_topup_amount'] as num).toDouble();
  final maximum = (row['max_topup_amount'] as num).toDouble();
  final feePercent = (row['fee_percent'] as num).toDouble();

  if (minimum <= 0 || maximum < minimum || feePercent < 0) {
    throw StateError('INVALID_TOPUP_LIMIT_CONFIG');
  }

  return TopUpLimits(
    minimum: minimum,
    maximum: maximum,
    feePercent: feePercent,
  );
}



  Future<TopUpIntent> start({
    required String gateway,
    required int amount,
    required String phone,
    String? medium,
    String? idempotencyKey,
  }) async {
    final data = await _functions.call<Map<String, dynamic>>(
      'start-top-up',
      data: {
        'gateway': gateway,
        'amount': amount,
        'phone': phone,
        'medium': ?medium,
        'idempotencyKey': idempotencyKey ?? const Uuid().v4(),
      },
    );
    return _fromMap(data['intentId'] as String, data);
  }

  Future<TopUpIntent> refresh(String intentId) async {
  final data = await _functions.call<Map<String, dynamic>>(
    'refresh-top-up',
    data: {'intentId': intentId},
  );

  return _fromMap(data['intentId'] as String, data);
}

  Stream<List<TopUpIntent>> watchRecent() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return Stream.value([]);
    return _client
        .from('payment_intents')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(20)
        .map(
          (rows) =>
              rows.map((row) => _fromMap(row['id'] as String, row)).toList(),
        );
  }

  TopUpIntent _fromMap(String id, Map<String, dynamic> data) {
    final gateway =
        data['gateway'] ??
        data['gateway_slug'] ??
        data['payment_gateways']?['slug'] ??
        '';
    final providerAmount = data['providerAmount'] ?? data['provider_amount'];
    return TopUpIntent(
      id: id,
      status: data['status'] as String? ?? 'PENDING',
      gateway: gateway as String,
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'USD',
      providerAmount: (providerAmount as num?)?.toInt() ?? 0,
      providerCurrency:
          (data['providerCurrency'] ?? data['provider_currency']) as String? ??
          '',
      fee: (data['fee'] as num?)?.toDouble() ?? 0,
      checkoutUrl: (data['checkoutUrl'] ?? data['checkout_url']) as String?,
      failureCode: (data['failureCode'] ?? data['failure_code']) as String?,
    );
  }
}
