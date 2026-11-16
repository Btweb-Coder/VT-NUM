import 'package:supabase_flutter/supabase_flutter.dart';

class ReferralRepository {
  ReferralRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<Map<String, dynamic>> getDashboard() async {
    final result = await _client.rpc('referral_get_dashboard');
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Invalid referral dashboard response.');
  }

  Future<Map<String, dynamic>> getHistory({int limit = 100}) async {
    final result = await _client.rpc(
      'referral_get_history',
      params: {'p_limit': limit},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Invalid referral history response.');
  }

  Future<String> requestWithdrawal({
    required double amountUsd,
    required String network,
    required String accountName,
    required String phoneNumber,
  }) async {
    final result = await _client.rpc(
      'referral_request_withdrawal',
      params: {
        'p_amount_usd': amountUsd,
        'p_network': network,
        'p_account_name': accountName.trim(),
        'p_phone_number': phoneNumber.trim(),
      },
    );
    if (result is String && result.isNotEmpty) return result;
    throw const FormatException('The withdrawal request was not created.');
  }
}
