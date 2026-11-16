import 'package:supabase_flutter/supabase_flutter.dart';

class WalletLedgerEntry {
  const WalletLedgerEntry({
    required this.id,
    required this.origin,
    required this.type,
    required this.amount,
    required this.currency,
    required this.createdAt,
  });

  final String id;
  final String origin;
  final String type;
  final double amount;
  final String currency;
  final DateTime createdAt;

  factory WalletLedgerEntry.fromMap(Map<String, dynamic> value) => WalletLedgerEntry(
    id: value['id'] as String,
    origin: value['source_system'] as String? ?? 'VT-NUM',
    type: '${value['entry_type']}',
    amount: (value['amount'] as num).toDouble(),
    currency: value['currency'] as String? ?? 'USD',
    createdAt: DateTime.tryParse('${value['created_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class WalletLedgerRepository {
  WalletLedgerRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  Future<List<WalletLedgerEntry>> loadRecent() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return const <WalletLedgerEntry>[];
    final rows = await _client.from('wallet_ledger_entries')
      .select('id,source_system,entry_type,amount,currency,created_at')
      .eq('user_id', userId)
      .order('created_at', ascending: false)
      .limit(50);
    return rows.map((row) => WalletLedgerEntry.fromMap(row)).toList();
  }
}
