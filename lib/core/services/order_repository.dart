import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/activation.dart';
import '../models/order.dart';

class OrderRepository {
  OrderRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;
  final SupabaseClient _client;

  Stream<List<Order>> watchOrders() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return Stream.value([]);
    return _client
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .map((rows) => rows.map(Order.fromMap).toList());
  }

  Stream<Order?> watchOrder(String orderId) => _client
      .from('orders')
      .stream(primaryKey: ['id'])
      .eq('id', orderId)
      .map((rows) => rows.isEmpty ? null : Order.fromMap(rows.first));

  Stream<List<Activation>> watchActiveActivations() => watchOrders().map(
    (orders) => orders
        .where(
          (order) => const {
            'PROVIDER_REQUESTING',
            'WAITING_FOR_SMS',
            'SMS_RECEIVED',
            'EXPIRING',
            'CANCELLING',
            'EXPIRED',
            'REPLACING',
          }.contains(order.rawStatus),
        )
        .map(Activation.fromOrder)
        .toList(),
  );
}
