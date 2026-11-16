class PricingRule {
  final String id;
  final String markupType;
  final double markupValue;
  final bool active;
  final double activationExtraFee;

  const PricingRule({
    required this.id,
    required this.markupType,
    required this.markupValue,
    required this.active,
    this.activationExtraFee = 0,
  });

  factory PricingRule.fromMap(
    String id,
    Map<String, dynamic> data,
  ) {
    return PricingRule(
      id: id,
      markupType: data['markupType'] ?? 'percentage',
      markupValue: (data['markupValue'] ?? 50).toDouble(),
      active: data['active'] ?? true,
      activationExtraFee:
          (data['activationExtraFee'] ?? 0).toDouble(),
    );
  }

  double calculateCustomerPrice(double providerPrice) {
    double price;

    if (markupType == 'percentage') {
      price = providerPrice +
          (providerPrice * markupValue / 100);
    } else if (markupType == 'fixed') {
      price = providerPrice + markupValue;
    } else {
      price = providerPrice;
    }

    return price + activationExtraFee;
  }
}