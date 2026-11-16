const tnumApplicationTimeoutSeconds = 360;

int tnumApplicationRemainingSeconds(DateTime deadline, {DateTime? now}) {
  final seconds = deadline.difference(now ?? DateTime.now()).inSeconds;
  return seconds.clamp(0, tnumApplicationTimeoutSeconds);
}

class TnumQuote {
  const TnumQuote({
    required this.id,
    required this.customerPriceCents,
    required this.expiresAt,
  });

  final String id;
  final int customerPriceCents;
  final DateTime expiresAt;

  factory TnumQuote.fromMap(Map<String, dynamic> value) => TnumQuote(
    id: value['id'] as String,
    customerPriceCents: (value['customer_price_cents'] as num).toInt(),
    expiresAt: DateTime.parse(value['expires_at'] as String),
  );
}

class TnumCatalogItem {
  const TnumCatalogItem({
    required this.serviceSlug,
    required this.countryCode,
    required this.serviceName,
    required this.countryName,
    required this.customerPriceCents,
    required this.availableCount,
  });

  final String serviceSlug;
  final int countryCode;
  final String serviceName;
  final String countryName;
  final int customerPriceCents;
  final int availableCount;

  factory TnumCatalogItem.fromMap(Map<String, dynamic> value) {
    final service = Map<String, dynamic>.from(value['services'] as Map? ?? {});
    final country = Map<String, dynamic>.from(value['countries'] as Map? ?? {});
    return TnumCatalogItem(
      serviceSlug: value['service_slug'] as String,
      countryCode: (value['country_code'] as num).toInt(),
      serviceName: '${service['name'] ?? value['service_slug']}',
      countryName: '${country['name'] ?? value['country_code']}',
      customerPriceCents: (value['customer_price_cents'] as num).toInt(),
      availableCount: (value['available_count'] as num? ?? 0).toInt(),
    );
  }
}
