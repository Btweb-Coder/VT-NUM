import 'package:flutter_test/flutter_test.dart';
import 'package:online_sim/core/models/activation.dart';
import 'package:online_sim/core/models/order.dart';

void main() {
  test('VT-NUM countdown never exceeds the six-minute application limit', () {
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    final activation = _activation(deadline);

    expect(Activation.applicationTimeoutSeconds, 360);
    expect(activation.remainingSeconds, lessThanOrEqualTo(360));
    expect(activation.remainingSeconds, greaterThan(350));
  });

  test('reconstructing an activation preserves its persisted absolute deadline', () {
    final persistedDeadline = DateTime.now().add(const Duration(seconds: 245));
    final order = Order.fromMap({
      'id': 'order-1',
      'service_name': 'Service',
      'country_name': 'Country',
      'phone_number': '+10000000000',
      'provider_id': 'provider-1',
      'provider_activation_id': 'operation-1',
      'provider_price': 1,
      'markup_percentage': 0,
      'customer_price': 1,
      'currency': 'USD',
      'status': 'WAITING_FOR_SMS',
      'created_at': DateTime.now().toIso8601String(),
      'assigned_at': DateTime.now().toIso8601String(),
      'expires_at': persistedDeadline.toUtc().toIso8601String(),
    });
    final activation = Activation.fromOrder(order);

    expect(activation.expiresAt.toUtc(), persistedDeadline.toUtc());
    expect(activation.remainingSeconds, lessThanOrEqualTo(245));
  });
}

Activation _activation(DateTime expiry) => Activation(
  id: 'order-1',
  service: 'Service',
  country: 'Country',
  countryFlag: '',
  phoneNumber: '+10000000000',
  providerId: 'provider-1',
  providerActivationId: 'operation-1',
  price: '1.00',
  currency: 'USD',
  status: ActivationStatus.waitingForSms,
  expiresAt: expiry,
);
