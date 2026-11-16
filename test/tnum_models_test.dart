import 'package:flutter_test/flutter_test.dart';
import 'package:online_sim/features/activate/data/tnum_activation.dart';

void main() {
  test('T-NUM catalog model consumes client price only', () {
    final item = TnumCatalogItem.fromMap({
      'service_slug': 'telegram',
      'country_code': 44,
      'customer_price_cents': 275,
      'available_count': 8,
      'services': {'name': 'Telegram'},
      'countries': {'name': 'United Kingdom'},
    });

    expect(item.serviceSlug, 'telegram');
    expect(item.countryCode, 44);
    expect(item.customerPriceCents, 275);
    expect(item.availableCount, 8);
  });

  test('T-NUM quote parses server accepted customer price', () {
    final quote = TnumQuote.fromMap({
      'id': 'quote-id',
      'customer_price_cents': 475,
      'expires_at': '2026-11-03T12:00:00Z',
    });

    expect(quote.id, 'quote-id');
    expect(quote.customerPriceCents, 475);
    expect(quote.expiresAt.toUtc(), DateTime.utc(2026, 11, 3, 12));
  });

  test('T-NUM application countdown uses the persisted deadline and caps at six minutes', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    expect(
      tnumApplicationRemainingSeconds(
        now.add(const Duration(minutes: 15)),
        now: now,
      ),
      360,
    );
    expect(
      tnumApplicationRemainingSeconds(
        now.add(const Duration(seconds: 245)),
        now: now,
      ),
      245,
    );
    expect(
      tnumApplicationRemainingSeconds(
        now.subtract(const Duration(seconds: 1)),
        now: now,
      ),
      0,
    );
  });
}
