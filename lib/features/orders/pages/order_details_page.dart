import 'package:flutter/material.dart';
import '../../../app/localization/app_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../app/theme/colors.dart';
import '../../../core/models/order.dart';

class OrderDetailsPage extends StatelessWidget {
  final Order order;

  const OrderDetailsPage({
    super.key,
    required this.order,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.strings.text('orders.details.title')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          20,
          10,
          20,
          35,
        ),
        children: [
          _statusHeader(context),

          const SizedBox(height: 18),

          _numberCard(context),

          const SizedBox(height: 15),

          _pricingCard(context),

          const SizedBox(height: 15),

          _orderInformation(context),

          const SizedBox(height: 15),

          _timeline(context),

          if (order.wasReplaced) ...[
            const SizedBox(height: 15),
            _replacementCard(context),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // STATUS
  // ============================================================

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

  Widget _statusHeader(BuildContext context) {
    final info = _statusInfo(context);

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: info.color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: info.color.withValues(alpha: .20),
        ),
      ),
      child: Column(
        children: [
          Icon(
            info.icon,
            color: info.color,
            size: 42,
          ),

          const SizedBox(height: 12),

          Text(
            info.title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 5),

          Text(
            info.description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // NUMBER
  // ============================================================

  Widget _numberCard(BuildContext context) {
    return _section(
      title: context.strings.text('orders.details.number'),
      icon: Icons.phone_outlined,
      child: Column(
        children: [
          Text(
            order.phoneNumber,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 8),

          Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    _countryFlag(),
    const SizedBox(width: 8),
    Flexible(
      child: Text(
        order.country,
        style: const TextStyle(
          color: AppColors.textSecondary,
        ),
      ),
    ),
  ],
),

          if (order.code != null) ...[
            const SizedBox(height: 18),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: AppColors.success
                    .withValues(alpha: .08),
                borderRadius:
                    BorderRadius.circular(15),
              ),
              child: Column(
                children: [
                  Text(
                    context.strings.text('orders.details.code_received'),
                    style: TextStyle(
                      color: AppColors.success,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    order.code!,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // PRICING
  // ============================================================

Widget _pricingCard(BuildContext context) {
  return _section(
    title: context.strings.text('orders.details.pricing'),
    icon: Icons.payments_outlined,
    child: _priceRow(
      context.strings.text('orders.details.price_paid'),
      '${order.customerPrice.toStringAsFixed(2)} ${order.currency}',
      highlighted: true,
    ),
  );
}

  Widget _priceRow(
    String label,
    String value, {
    bool highlighted = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: highlighted
                  ? AppColors.textPrimary
                  : AppColors.textSecondary,
              fontWeight: highlighted
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: highlighted
                ? AppColors.primary
                : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // INFORMATION
  // ============================================================

  Widget _orderInformation(BuildContext context) {
    return _section(
      title: context.strings.text('orders.details.information'),
      icon: Icons.info_outline,
      child: Column(
        children: [
          _infoRow(
            context.strings.text('orders.details.command'),
            order.id,
          ),

          _infoRow(
            context.strings.text('orders.details.service'),
            order.service,
          ),

          _infoRow(
            context.strings.text('orders.details.created_at'),
            _formatDate(order.createdAt),
          ),

          if (order.assignedAt != null)
            _infoRow(
              context.strings.text('orders.details.number_assigned'),
              _formatDate(order.assignedAt!),
            ),

          if (order.expiresAt != null)
            _infoRow(
              context.strings.text('orders.details.expiration'),
              _formatDate(order.expiresAt!),
            ),

          if (order.completedAt != null)
            _infoRow(
              context.strings.text('orders.details.completed_at'),
              _formatDate(order.completedAt!),
            ),

          if (order.cancelledAt != null)
            _infoRow(
              context.strings.text('orders.details.cancelled_at'),
              _formatDate(order.cancelledAt!),
            ),
        ],
      ),
    );
  }

  Widget _infoRow(
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 15),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // TIMELINE
  // ============================================================

  Widget _timeline(BuildContext context) {
    final events = <_TimelineEvent>[
      _TimelineEvent(
        context.strings.text('orders.details.order_created'),
        _formatDate(order.createdAt),
        true,
      ),
      if (order.assignedAt != null)
        _TimelineEvent(
          context.strings.text('orders.details.number_assigned'),
          _formatDate(order.assignedAt!),
          true,
        ),
      if (order.status ==
          OrderStatus.waitingForSms)
        _TimelineEvent(
          context.strings.text('orders.details.waiting_sms'),
          context.strings.text('orders.details.in_progress'),
          true,
        ),
      if (order.completedAt != null)
        _TimelineEvent(
          context.strings.text('orders.details.code_received_label'),
          _formatDate(order.completedAt!),
          true,
        ),
      if (order.status ==
          OrderStatus.expired)
        _TimelineEvent(
          context.strings.text('orders.details.activation_expired'),
          order.expiresAt == null
              ? ''
              : _formatDate(order.expiresAt!),
          true,
        ),
      if (order.cancelledAt != null)
        _TimelineEvent(
          context.strings.text('orders.details.activation_cancelled'),
          _formatDate(order.cancelledAt!),
          true,
        ),
      if (order.status ==
          OrderStatus.refunded)
        _TimelineEvent(
          context.strings.text('orders.details.amount_refunded'),
          context.strings.text('orders.details.completed'),
          true,
        ),
    ];

    return _section(
      title: context.strings.text('orders.details.history'),
      icon: Icons.timeline,
      child: Column(
        children: [
          for (var i = 0;
              i < events.length;
              i++)
            _timelineItem(
              events[i],
              isLast: i == events.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _timelineItem(
    _TimelineEvent event, {
    required bool isLast,
  }) {
    return Row(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),

            if (!isLast)
              Container(
                width: 1,
                height: 42,
                color: AppColors.border,
              ),
          ],
        ),

        const SizedBox(width: 14),

        Expanded(
          child: Padding(
            padding:
                const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  event.subtitle,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // REPLACEMENT
  // ============================================================

  Widget _replacementCard(BuildContext context) {
    return _section(
      title: context.strings.text('orders.details.replacement'),
      icon: Icons.swap_horiz,
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          if (order.replacedOrderId != null)
            _infoRow(
              context.strings.text('orders.details.previous_order'),
              order.replacedOrderId!,
            ),

          if (order.replacementOrderId != null)
            _infoRow(
              context.strings.text('orders.details.new_order'),
              order.replacementOrderId!,
            ),

          const SizedBox(height: 5),

          Text(
            context.strings.text('orders.details.chain_message'),
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // SECTION
  // ============================================================

  Widget _section({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),

          child,
        ],
      ),
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  String _formatDate(DateTime date) {
    final day =
        date.day.toString().padLeft(2, '0');
    final month =
        date.month.toString().padLeft(2, '0');

    return '$day/$month/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  _OrderStatusInfo _statusInfo(BuildContext context) {
    switch (order.status) {
      case OrderStatus.completed:
        return _OrderStatusInfo(
          context.strings.text('orders.details.activation_completed'),
          context.strings.text('orders.details.code_received_message'),
          AppColors.success,
          Icons.check_circle_outline,
        );

      case OrderStatus.expired:
        return _OrderStatusInfo(
          context.strings.text('orders.details.activation_expired'),
          context.strings.text('orders.details.no_code_message'),
          AppColors.warning,
          Icons.timer_off_outlined,
        );

      case OrderStatus.cancelled:
        return _OrderStatusInfo(
          context.strings.text('orders.details.activation_cancelled'),
          context.strings.text('orders.details.cancelled_message'),
          AppColors.error,
          Icons.cancel_outlined,
        );

      case OrderStatus.refunded:
        return _OrderStatusInfo(
          context.strings.text('orders.details.amount_refunded'),
          context.strings.text('orders.details.refunded_message'),
          AppColors.violet,
          Icons.currency_exchange,
        );

      case OrderStatus.failed:
        return _OrderStatusInfo(
          context.strings.text('orders.details.activation_failed'),
          context.strings.text('orders.details.request_failed_message'),
          AppColors.error,
          Icons.error_outline,
        );

      case OrderStatus.waitingForSms:
        return _OrderStatusInfo(
          context.strings.text('orders.details.waiting_code'),
          context.strings.text('orders.details.waiting_message'),
          AppColors.primary,
          Icons.sms_outlined,
        );

      case OrderStatus.requesting:
        return _OrderStatusInfo(
          context.strings.text('orders.details.processing'),
          context.strings.text('orders.details.processing_message'),
          AppColors.primary,
          Icons.sync,
        );

      case OrderStatus.replacing:
        return _OrderStatusInfo(
          context.strings.text('orders.details.replacing'),
          context.strings.text('orders.details.replacing_message'),
          AppColors.violet,
          Icons.swap_horiz,
        );
    }
  }
}

class _OrderStatusInfo {
  final String title;
  final String description;
  final Color color;
  final IconData icon;

  const _OrderStatusInfo(
    this.title,
    this.description,
    this.color,
    this.icon,
  );
}

class _TimelineEvent {
  final String title;
  final String subtitle;
  final bool completed;

  const _TimelineEvent(
    this.title,
    this.subtitle,
    this.completed,
  );
}

