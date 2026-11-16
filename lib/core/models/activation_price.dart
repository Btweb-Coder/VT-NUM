class ActivationPrice {
  final double providerPrice;
  final double markupPercentage;
  final double customerPrice;
  final String currency;

  const ActivationPrice({
    required this.providerPrice,
    required this.markupPercentage,
    required this.customerPrice,
    required this.currency,
  });

  factory ActivationPrice.calculate({
    required double providerPrice,
    required double markupPercentage,
    required String currency,
  }) {
    final customerPrice =
        providerPrice + (providerPrice * markupPercentage / 100);

    return ActivationPrice(
      providerPrice: providerPrice,
      markupPercentage: markupPercentage,
      customerPrice: customerPrice,
      currency: currency,
    );
  }
}