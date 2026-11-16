
import 'package:supabase_flutter/supabase_flutter.dart';

class PaymentGateway {
  const PaymentGateway({
    required this.slug,
    required this.name,
    this.exchangeRate,
    this.providerCurrency,
  });

  final String slug;
  final String name;
  final double? exchangeRate;
  final String? providerCurrency;
}

class PaymentGatewayRepository {
  PaymentGatewayRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<PaymentGateway>> loadActive() async {
    final rows = await _client
        .from('payment_gateways')
        .select('slug, exchange_rate, provider_currency')
        .eq('active', true)
        .order('slug');

    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map((row) {
          final slug = row['slug'] as String;
          final rate = row['exchange_rate'];

          return PaymentGateway(
            slug: slug,
            name: _name(slug),
            exchangeRate: rate is num ? rate.toDouble() : null,
            providerCurrency: row['provider_currency'] as String?,
          );
        })
        .toList();
  }

  String _name(String slug) => switch (slug) {
        'fapshi' => 'Fapshi',
        'cinetpay' => 'CinetPay',
        'transfluo' => 'Transfluo',
        _ => slug,
      };
}
