import 'package:flutter/material.dart';

import '../../app/localization/app_localizations.dart';
import '../../app/theme/colors.dart';
import '../models/order.dart';
import 'package:flutter_svg/flutter_svg.dart';

class OrderCard extends StatelessWidget {
  final Order order;
  final VoidCallback? onTap;

  const OrderCard({
    super.key,
    required this.order,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = _statusInfo(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.border,
          ),
        ),
        child: Row(
          children: [
            _serviceIcon(),

            const SizedBox(width: 13),

            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          order.service,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _statusBadge(status),
                    ],
                  ),

                  const SizedBox(height: 5),

                  Row(
  children: [
    _countryFlag(),
    const SizedBox(width: 6),
    Expanded(
      child: Text(
        order.country,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    ),
  ],
),

                  const SizedBox(height: 8),

                  Row(
                    children: [
                      const Icon(
                        Icons.phone_outlined,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        order.phoneNumber,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            const Icon(
              Icons.chevron_right,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _countryFlag() {
  final value = order.countryFlag.trim();

  if (value.isEmpty) {
    return const Icon(
      Icons.public,
      size: 16,
      color: AppColors.textSecondary,
    );
  }

  // Le champ contient une URL de drapeau.
  if (value.startsWith('https://') ||
      value.startsWith('http://')) {
    if (value.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        value,
        width: 22,
        height: 16,
        placeholderBuilder: (_) => const Icon(
          Icons.public,
          size: 16,
          color: AppColors.textSecondary,
        ),
      );
    }

    return Image.network(
      value,
      width: 22,
      height: 16,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const Icon(
        Icons.public,
        size: 16,
        color: AppColors.textSecondary,
      ),
    );
  }

  // Si le champ contient déjà un emoji, on le conserve.
  return Text(
    value,
    style: const TextStyle(fontSize: 16),
  );
}

  Widget _serviceIcon() {
    return Container(
      width: 45,
      height: 45,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(
          alpha: .10,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        _iconForService(),
        color: AppColors.primary,
      ),
    );
  }

  Widget _statusBadge(
    _OrderStatusInfo status,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: status.color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  _OrderStatusInfo _statusInfo(BuildContext context) {
    switch (order.status) {
      case OrderStatus.completed:
        return _OrderStatusInfo(
          context.strings.text('orders.status.completed'),
          AppColors.success,
        );

      case OrderStatus.waitingForSms:
        return _OrderStatusInfo(
          context.strings.text('orders.status.waiting'),
          AppColors.primary,
        );

      case OrderStatus.expired:
        return _OrderStatusInfo(
          context.strings.text('orders.status.expired'),
          AppColors.warning,
        );

      case OrderStatus.cancelled:
        return _OrderStatusInfo(
          context.strings.text('orders.status.cancelled'),
          AppColors.error,
        );

      case OrderStatus.failed:
        return _OrderStatusInfo(
          context.strings.text('orders.status.failed'),
          AppColors.error,
        );

      case OrderStatus.refunded:
        return _OrderStatusInfo(
          context.strings.text('orders.status.refunded'),
          AppColors.violet,
        );

      case OrderStatus.requesting:
        return _OrderStatusInfo(
          context.strings.text('orders.status.processing'),
          AppColors.primary,
        );

      case OrderStatus.replacing:
        return _OrderStatusInfo(
          context.strings.text('orders.status.replacing'),
          AppColors.violet,
        );
    }
  }

  IconData _iconForService() {
    switch (order.service) {
      case 'Telegram':
        return Icons.send;

      case 'Instagram':
        return Icons.camera_alt_outlined;

      case 'Facebook':
        return Icons.facebook;

      case 'TikTok':
        return Icons.music_note;

      default:
        return Icons.chat;
    }
  }
}

class _OrderStatusInfo {
  final String label;
  final Color color;

  const _OrderStatusInfo(
    this.label,
    this.color,
  );
}

// ${order.country}',
