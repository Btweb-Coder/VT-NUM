import 'package:supabase_flutter/supabase_flutter.dart';

class WalletSnapshot {
  const WalletSnapshot({required this.available, required this.held, required this.currency});
  final double available;
  final double held;
  final String currency;
}

class WalletRepository {
  WalletRepository({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  Stream<WalletSnapshot?> watchWallet() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return Stream.value(null);
    return _client.from('wallets').stream(primaryKey: ['user_id']).eq('user_id', uid).map((rows) {
      if (rows.isEmpty) return null;
      final data = rows.first;
      return WalletSnapshot(
        available: (data['available_balance'] as num?)?.toDouble() ?? 0,
        held: (data['held_balance'] as num?)?.toDouble() ?? 0,
        currency: data['currency'] as String? ?? 'USD',
      );
    });
  }
}
