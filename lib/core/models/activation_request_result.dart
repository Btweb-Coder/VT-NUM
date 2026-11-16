class ActivationRequestResult {
  final String orderId;
  final String serviceId;
  final String countryId;
  final String countryFlag;

  final String phoneNumber;

  final String providerId;
  final String providerActivationId;

  final double providerPrice;
  final double markupPercentage;
  final double customerPrice;

  final String currency;

  final DateTime expiresAt;

  const ActivationRequestResult({
    required this.orderId,
    required this.serviceId,
    required this.countryId,
    required this.countryFlag,
    required this.phoneNumber,
    required this.providerId,
    required this.providerActivationId,
    required this.providerPrice,
    required this.markupPercentage,
    required this.customerPrice,
    required this.currency,
    required this.expiresAt,
  });

  factory ActivationRequestResult.fromMap(
    Map<String, dynamic> data,
  ) {
    return ActivationRequestResult(
      orderId: data['orderId'] ?? '',
      serviceId: data['serviceId'] ?? '',
      countryId: data['countryId'] ?? '',
      countryFlag: data['countryFlag'] ?? '',
      phoneNumber: data['phoneNumber'] ?? '',
      providerId: data['providerId'] ?? '',
      providerActivationId:
          data['providerActivationId'] ?? '',
      providerPrice:
          (data['providerPrice'] ?? 0).toDouble(),
      markupPercentage:
          (data['markupPercentage'] ?? 0).toDouble(),
      customerPrice:
          (data['customerPrice'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'XAF',
      expiresAt: DateTime.parse(
        data['expiresAt'],
      ),
    );
  }
}