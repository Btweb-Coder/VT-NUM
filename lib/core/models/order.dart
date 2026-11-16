
enum OrderStatus {
  requesting,
  waitingForSms,
  completed,
  expired,
  cancelled,
  replacing,
  failed,
  refunded,
}

class Order {
  final String id;

  final String service;
  final String country;
  final String countryFlag;

  final String phoneNumber;

  final String providerId;
  final String providerActivationId;

  final double providerPrice;
  final double markupPercentage;
  final double customerPrice;
  final String currency;

  final OrderStatus status;
  final String rawStatus;

  final DateTime createdAt;
  final DateTime? assignedAt;
  final DateTime? expiresAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;

  final String? code;

  /// If this order was created through
  /// "AUTRE NUMÉRO", this points to the
  /// previous order.
  final String? replacedOrderId;

  /// If this order was later replaced,
  /// this points to the new order.
  final String? replacementOrderId;

  const Order({
    required this.id,
    required this.service,
    required this.country,
    required this.countryFlag,
    required this.phoneNumber,
    required this.providerId,
    required this.providerActivationId,
    required this.providerPrice,
    required this.markupPercentage,
    required this.customerPrice,
    required this.currency,
    required this.status,
    this.rawStatus = 'CREATED',
    required this.createdAt,
    this.assignedAt,
    this.expiresAt,
    this.completedAt,
    this.cancelledAt,
    this.code,
    this.replacedOrderId,
    this.replacementOrderId,
  });

  bool get isCompleted =>
      status == OrderStatus.completed;

  bool get isSuccessful =>
      status == OrderStatus.completed;

  bool get isFailed =>
      status == OrderStatus.failed;

  bool get isExpired =>
      status == OrderStatus.expired;

  bool get isCancelled =>
      status == OrderStatus.cancelled;

  bool get wasReplaced =>
      replacedOrderId != null ||
      replacementOrderId != null;

  factory Order.fromMap(Map<String, dynamic> data) {
    DateTime? date(String field) => data[field] == null ? null : DateTime.tryParse(data[field].toString());
    final rawStatus = data['status'] as String? ?? 'CREATED';
    return Order(
      id: data['id'] as String,
      service: data['service_name'] as String? ?? data['service_code'] as String? ?? '',
      country: data['country_name'] as String? ?? data['country_code'] as String? ?? '',
      countryFlag: data['country_flag'] as String? ?? '',
      phoneNumber: data['phone_number'] as String? ?? '',
      providerId: data['provider_id'] as String? ?? '',
      providerActivationId: data['provider_activation_id'] as String? ?? '',
      providerPrice: (data['provider_price'] as num?)?.toDouble() ?? 0,
      markupPercentage: (data['markup_percentage'] as num?)?.toDouble() ?? 0,
      customerPrice: (data['customer_price'] as num?)?.toDouble() ?? 0,
      currency: data['currency'] as String? ?? 'USD',
      status: _statusFromRaw(rawStatus), rawStatus: rawStatus,
      createdAt: date('created_at') ?? DateTime.fromMillisecondsSinceEpoch(0),
      assignedAt: date('assigned_at'), expiresAt: date('expires_at'), completedAt: date('completed_at'), cancelledAt: date('cancelled_at'),
      code: data['code'] as String?, replacedOrderId: data['replaced_order_id'] as String?, replacementOrderId: data['replacement_order_id'] as String?,
    );
  }

  static OrderStatus _statusFromRaw(String value) => switch (value) {
    'WAITING_FOR_SMS' => OrderStatus.waitingForSms,
    'SMS_RECEIVED' || 'COMPLETED' => OrderStatus.completed,
    'EXPIRED' => OrderStatus.expired,
    'CANCELLED' => OrderStatus.cancelled,
    'REPLACING' => OrderStatus.replacing,
    'FAILED' => OrderStatus.failed,
    _ => OrderStatus.requesting,
  };
}
