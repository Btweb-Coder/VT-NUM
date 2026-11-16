import 'order.dart';

enum ActivationStatus {
  requesting,
  waitingForSms,
  codeReceived,
  completed,
  expiring,
  expired,
  cancelling,
  cancelled,
  replacing,
  failed,
}

class Activation {
  static const int applicationTimeoutSeconds = 360;
  final bool wasReplaced;
  final String id;

  final String service;
  final String country;
  final String countryFlag;

  final String phoneNumber;

  final String providerId;
  final String providerActivationId;

  final String price;
  final String currency;

  final String? code;

  final ActivationStatus status;

  /// Server-side expiration timestamp.
  ///
  /// In production this comes from the server-side database.
  final DateTime expiresAt;

  const Activation({
    this.wasReplaced = false,
    required this.id,
    required this.service,
    required this.country,
    required this.countryFlag,
    required this.phoneNumber,
    required this.providerId,
    required this.providerActivationId,
    required this.price,
    required this.currency,
    required this.status,
    required this.expiresAt,
    this.code,
  });

  bool get isWaiting => status == ActivationStatus.waitingForSms;

  bool get hasCode =>
      status == ActivationStatus.codeReceived ||
      status == ActivationStatus.completed;

  bool get isExpired => status == ActivationStatus.expired;

  bool get isProcessing =>
    !wasReplaced &&
    (status == ActivationStatus.requesting ||
        status == ActivationStatus.expiring ||
        status == ActivationStatus.cancelling ||
        status == ActivationStatus.replacing);

  /// This is calculated locally only for display.
  ///
  /// The backend remains the source of truth.
  int get remainingSeconds {
    final difference = expiresAt.difference(DateTime.now()).inSeconds;

    if (difference <= 0) {
      return 0;
    }

    // Persisted expiries are the source of truth, but old rows or a provider
    // supplied lifetime must never make the VT-NUM display exceed six minutes.
    return difference.clamp(0, applicationTimeoutSeconds);
  }

Activation copyWith({
  bool? wasReplaced,
  ActivationStatus? status,
  String? phoneNumber,
  String? providerId,
  String? providerActivationId,
  String? price,
  String? currency,
  String? code,
  DateTime? expiresAt,
}) {
  return Activation(
    wasReplaced: wasReplaced ?? this.wasReplaced,
    id: id,
    service: service,
    country: country,
    countryFlag: countryFlag,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    providerId: providerId ?? this.providerId,
    providerActivationId:
        providerActivationId ?? this.providerActivationId,
    price: price ?? this.price,
    currency: currency ?? this.currency,
    status: status ?? this.status,
    expiresAt: expiresAt ?? this.expiresAt,
    code: code ?? this.code,
  );
}


  factory Activation.fromOrder(Order order) => Activation(
    wasReplaced: order.replacementOrderId != null,
    id: order.id,
    service: order.service,
    country: order.country,
    countryFlag: order.countryFlag,
    phoneNumber: order.phoneNumber,
    providerId: order.providerId,
    providerActivationId: order.providerActivationId,
    price: order.customerPrice.toStringAsFixed(2),
    currency: order.currency,
    code: order.code,
    status: switch (order.rawStatus) {
      'WAITING_FOR_SMS' => ActivationStatus.waitingForSms,
      'SMS_RECEIVED' => ActivationStatus.codeReceived,
      'EXPIRING' => ActivationStatus.expiring,
      'CANCELLING' => ActivationStatus.cancelling,
      'EXPIRED' => ActivationStatus.expired,
      'CANCELLED' => ActivationStatus.cancelled,
      'REPLACING' => ActivationStatus.replacing,
      _ => ActivationStatus.requesting,
    },
    expiresAt: order.expiresAt ?? DateTime.now(),
  );
}
// bool get isProcessing =>
