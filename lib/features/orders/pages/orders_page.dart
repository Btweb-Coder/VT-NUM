import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../app/localization/app_localizations.dart';

import '../../../core/models/order.dart';
import '../../../core/services/order_repository.dart';
import '../../../core/widgets/order_card.dart';
import 'order_details_page.dart';
import 'tnum_operation_details_page.dart';
import '../../activate/data/tnum_repository.dart';
import '../../activate/widgets/tnum_feedback.dart';

class _OrdersPremiumBackground extends StatefulWidget {
  final Widget child;

  const _OrdersPremiumBackground({required this.child});

  @override
  State<_OrdersPremiumBackground> createState() =>
      _OrdersPremiumBackgroundState();
}

class _OrdersPremiumBackgroundState extends State<_OrdersPremiumBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 28),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF050816),
                Color(0xFF0A1028),
                Color(0xFF15102F),
                Color(0xFF070B19),
              ],
            ),
          ),
        ),

        Positioned(
          top: -100,
          right: -110,
          child: _glow(300, const Color(0xFF5145FF)),
        ),

        Positioned(
          top: 370,
          left: -160,
          child: _glow(310, const Color(0xFF0878F9)),
        ),

        Positioned(
          bottom: -150,
          right: -100,
          child: _glow(330, const Color(0xFF7C3AED)),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _OrdersStarsPainter(progress: _controller.value),
                );
              },
            ),
          ),
        ),

        widget.child,
      ],
    );
  }

  Widget _glow(double size, Color color) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: 0.20),
              color.withValues(alpha: 0.07),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrdersStarsPainter extends CustomPainter {
  final double progress;

  _OrdersStarsPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final paint = Paint();

    for (int i = 0; i < 75; i++) {
      final x = ((i * 73.37) % 997) / 997 * size.width;
      final baseY = ((i * 47.91) % 991) / 991 * size.height;
      final drift = (progress * 24 + i * 1.7) % 24;
      final y = (baseY + drift) % size.height;

      final phase = progress * math.pi * 2 + i * 0.83;

      final opacity = (0.12 + 0.48 * ((math.sin(phase) + 1) / 2))
          .clamp(0.0, 1.0)
          .toDouble();

      paint.color = Colors.white.withValues(alpha: opacity);

      canvas.drawCircle(Offset(x, y), i % 9 == 0 ? 1.6 : 0.8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _OrdersStarsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  late Future<List<Map<String, dynamic>>> _tnumHistory = TnumRepository()
      .activations(history: true);

  @override
  Widget build(BuildContext context) {
    return _OrdersPremiumBackground(
      child: SafeArea(
        child: StreamBuilder<List<Order>>(
          stream: OrderRepository().watchOrders(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _buildError(context);
            }

            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFF8B9BFF)),
              );
            }

            final orders = snapshot.data!;

            return FutureBuilder<List<Map<String, dynamic>>>(
              future: _tnumHistory,
              builder: (context, historySnapshot) {
                final tnumRows =
                    historySnapshot.data ?? const <Map<String, dynamic>>[];
                final operationCount = orders.length + tnumRows.length;
                final operationTiles =
                    <({DateTime createdAt, Widget child})>[
                      ...orders.map(
                        (order) => (
                          createdAt: order.createdAt,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              children: [
                                _originBadge(
                                  context.strings.text('tnum.origin_vt'),
                                ),
                                OrderCard(
                                  order: order,
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          OrderDetailsPage(order: order),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      ...tnumRows.map(
                        (row) => (
                          createdAt:
                              DateTime.tryParse('${row['created_at']}') ??
                              DateTime.fromMillisecondsSinceEpoch(0),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _tnumHistoryCard(context, row),
                          ),
                        ),
                      ),
                    ]..sort(
                      (left, right) =>
                          right.createdAt.compareTo(left.createdAt),
                    );
                return RefreshIndicator(
                  color: const Color(0xFF8B9BFF),
                  backgroundColor: const Color(0xFF111A32),
                  onRefresh: () async {
                    setState(
                      () => _tnumHistory = TnumRepository().activations(
                        history: true,
                      ),
                    );
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                    children: [
                      _buildHeader(context),

                      const SizedBox(height: 25),

                      _buildOverviewCard(context, operationCount),

                      const SizedBox(height: 29),

                      _buildSectionHeader(context, operationCount),

                      const SizedBox(height: 16),

                      if (operationTiles.isEmpty)
                        _buildEmptyState(context)
                      else
                        ...operationTiles.map((item) => item.child),
                      if (historySnapshot.hasError)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            context.strings.text(
                              TnumFeedbackMessage.fromError(
                                historySnapshot.error!,
                              ).messageKey,
                            ),
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),

                      const SizedBox(height: 18),

                      _buildFooter(context),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _tnumHistoryCard(BuildContext context, Map<String, dynamic> row) {
    final status = tnumStatusLabel(context, '${row['status'] ?? ''}');
    final price = ((row['customer_price_cents'] as num? ?? 0) / 100)
        .toStringAsFixed(2);
    final country = Map<String, dynamic>.from(row['countries'] as Map? ?? {});
    final service = Map<String, dynamic>.from(row['services'] as Map? ?? {});
    return Card(
      color: const Color(0xFF151D36),
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                TnumOperationDetailsPage(activationId: '${row['id']}'),
          ),
        ),
        leading: const CircleAvatar(child: Text('T')),
        title: Text(
          '${service['name'] ?? row['service_slug']}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${context.strings.text('tnum.origin')} · ${country['name'] ?? row['country_code']} · $status',
          style: const TextStyle(color: Color(0xFFA5B4D0)),
        ),
        trailing: Text(
          '\$$price',
          style: const TextStyle(
            color: Color(0xFF6EE7B7),
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _originBadge(String label) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 4),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF8FB6FF),
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF4776FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                    blurRadius: 22,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: const Icon(
                Icons.receipt_long_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),

            const Spacer(),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFF718BFF).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF718BFF).withValues(alpha: 0.24),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 15,
                    color: Color(0xFFB8C7FF),
                  ),
                  SizedBox(width: 7),
                  Text(
                    context.strings.text('orders.history_label'),
                    style: TextStyle(
                      color: Color(0xFFB8C7FF),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 23),

        Text(
          context.strings.text('orders.title'),
          style: TextStyle(
            color: Colors.white,
            fontSize: 31,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
          ),
        ),

        const SizedBox(height: 9),

        Text(
          context.strings.text('orders.subtitle'),
          style: TextStyle(color: Color(0xFFA5B4D0), fontSize: 14, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildOverviewCard(BuildContext context, int count) {
    return Container(
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF273D78), Color(0xFF29245B), Color(0xFF3A205F)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5145FF).withValues(alpha: 0.14),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),

          const SizedBox(width: 15),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.strings.text('orders.saved_count'),
                  style: TextStyle(
                    color: Color(0xFFD0D9FF),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),

                const SizedBox(height: 7),

                Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  count == 0
                      ? context.strings.text('orders.empty_title')
                      : count == 1
                      ? context.strings.text('orders.one_order')
                      : context.strings.text('orders.many_orders'),
                  style: const TextStyle(
                    color: Color(0xFFD0D9FF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          const Icon(Icons.auto_awesome, color: Color(0xFFC4B5FD), size: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, int count) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('orders.all'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 5),
              Text(
                context.strings.text('orders.details_subtitle'),
                style: TextStyle(color: Color(0xFF8998B7), fontSize: 12),
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF718BFF).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF718BFF).withValues(alpha: 0.20),
            ),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: Color(0xFFB8C7FF),
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFF8B9BFF)),
          SizedBox(height: 18),
          Text(
            context.strings.text('orders.none'),
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 8),
          Text(
            context.strings.text('orders.empty_message'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFA5B4D0),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
            color: const Color(0xFF111A32),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 42, color: Color(0xFFFF7B8B)),
              SizedBox(height: 16),
              Text(
                context.strings.text('orders.load_error'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 16,
            color: Colors.white.withValues(alpha: 0.40),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              context.strings.text('common.brand_descriptor'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 10,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
