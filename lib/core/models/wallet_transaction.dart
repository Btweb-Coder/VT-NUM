enum WalletTransactionType {
  deposit,
  hold,
  releaseHold,
  captureHold,
  purchase,
  refund,
  adjustment,
  bonus,
  withdrawal,
}

enum WalletTransactionStatus {
  pending,
  completed,
  failed,
}

class WalletTransaction {
  final String id;
  final WalletTransactionType type;
  final WalletTransactionStatus status;

  final double amount;
  final String currency;

  final String? orderId;
  final String? description;

  final DateTime createdAt;

  const WalletTransaction({
    required this.id,
    required this.type,
    required this.status,
    required this.amount,
    required this.currency,
    required this.createdAt,
    this.orderId,
    this.description,
  });
}