import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../app/localization/app_localizations.dart';
// import '../../../app/theme/colors.dart';
import '../../../core/models/activation.dart';
import '../../../core/services/audit_service.dart';
import '../../../core/services/order_repository.dart';
import '../../activate/data/activation_repository.dart';
import '../../../core/widgets/activation_card.dart';
import '../widgets/tnum_active_section.dart';
import '../../onboarding/first_time_app_guide.dart';

class _ActivePremiumBackground extends StatefulWidget {
  final Widget child;

  const _ActivePremiumBackground({
    required this.child,
  });

  @override
  State<_ActivePremiumBackground> createState() =>
      _ActivePremiumBackgroundState();
}

class _ActivePremiumBackgroundState
    extends State<_ActivePremiumBackground>
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
          right: -100,
          child: _glow(290, const Color(0xFF5145FF)),
        ),

        Positioned(
          top: 330,
          left: -150,
          child: _glow(290, const Color(0xFF0878F9)),
        ),

        Positioned(
          bottom: -150,
          right: -100,
          child: _glow(320, const Color(0xFF7C3AED)),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ActiveStarsPainter(
                    progress: _controller.value,
                  ),
                );
              },
            ),
          ),
        ),

        widget.child,
      ],
    );
  }
}

class _ActiveStarsPainter extends CustomPainter {
  final double progress;

  _ActiveStarsPainter({
    required this.progress,
  });

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

      final opacity =
          (0.12 + 0.48 * ((math.sin(phase) + 1) / 2))
              .clamp(0.0, 1.0)
              .toDouble();

      paint.color = Colors.white.withValues(alpha: opacity);

      canvas.drawCircle(
        Offset(x, y),
        i % 9 == 0 ? 1.6 : 0.8,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ActiveStarsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class ActivePage extends StatefulWidget {
  const ActivePage({super.key});

  @override
  State<ActivePage> createState() => _ActivePageState();
}

class _ActivePageState extends State<ActivePage> {
  final _orders = OrderRepository();
  final _activations = ActivationRepository();
  final _audit = AuditService();

  Timer? _timer;

  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ActivePremiumBackground(
      child: SafeArea(
        child: StreamBuilder<List<Activation>>(
          stream: _orders.watchActiveActivations(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _message(
                context.strings.text('active.load_error'),
              );
            }

            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF8B9BFF),
                ),
              );
            }

            final activations = snapshot.data!;

            return RefreshIndicator(
              color: const Color(0xFF8B9BFF),
              backgroundColor: const Color(0xFF111A32),
              onRefresh: () async {},
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                children: [
                  _buildHeader(),

                  const SizedBox(height: 25),

                  _buildOverviewCard(activations.length),

                  const SizedBox(height: 29),

                  FirstTimeAppGuide.anchor('active', 'ACTIVE NUMBERS LIST', _buildSectionHeader(activations.length)),

                  const SizedBox(height: 16),

                  if (activations.isEmpty)
                    _message(context.strings.text('active.none'))
                  else
                    ...activations.asMap().entries.map((entry) {
                      final activation = entry.value;
                      final card = Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(children: [
                          Align(alignment: Alignment.centerLeft,
                            child: Padding(padding: const EdgeInsets.only(left: 12, bottom: 4),
                              child: Text(context.strings.text('tnum.origin_vt'),
                                style: const TextStyle(color: Color(0xFF8FB6FF), fontSize: 10, fontWeight: FontWeight.w900)))),
                          ActivationCard(
                            activation: activation,
                            onCancel: () => _cancel(activation),
                            onGetAnotherNumber: () => _replace(activation),
                          ),
                        ]),
                      );
                      return entry.key == 0
                          ? FirstTimeAppGuide.anchor(
                              'active',
                              'AVAILABLE ACTIONS',
                              FirstTimeAppGuide.anchor('active', 'NUMBER AND STATUS', card),
                            )
                          : card;
                    }),

                  const SizedBox(height: 20),
                  FirstTimeAppGuide.anchor(
                    'active',
                    'SMS / VERIFICATION CODE',
                    const TnumActiveSection(),
                  ),

                  const SizedBox(height: 18),

                  _buildFooter(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader() {
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
                  colors: [
                    Color(0xFF4776FF),
                    Color(0xFF8B5CF6),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1)
                        .withValues(alpha: 0.25),
                    blurRadius: 22,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: const Icon(
                Icons.sim_card_rounded,
                color: Colors.white,
                size: 29,
              ),
            ),

            const Spacer(),

            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.circle,
                    size: 7,
                    color: Color(0xFF34D399),
                  ),
                  SizedBox(width: 7),
                  Text(
                    context.strings.text('active.live').toUpperCase(),
                    style: TextStyle(
                      color: Color(0xFF6EE7B7),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 23),

        Text(
          context.strings.text('active.title'),
          style: TextStyle(
            color: Colors.white,
            fontSize: 31,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
          ),
        ),

        const SizedBox(height: 9),

        Text(
          context.strings.text('active.subtitle'),
          style: TextStyle(
            color: Color(0xFFA5B4D0),
            fontSize: 14,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildOverviewCard(int count) {
    return Container(
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF273D78),
            Color(0xFF29245B),
            Color(0xFF3A205F),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
        ),
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
              Icons.phone_android_rounded,
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
                  context.strings.text('active.followed_count').toUpperCase(),
                  style: TextStyle(
                    color: Color(0xFFD0D9FF),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
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
                      ? context.strings.text('active.none')
                      : count == 1
                          ? context.strings.text('active.one_followed')
                          : context.strings.text('active.many_followed'),
                  style: const TextStyle(
                    color: Color(0xFFD0D9FF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          const Icon(
            Icons.auto_awesome,
            color: Color(0xFFC4B5FD),
            size: 24,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(int count) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('active.my_activations'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 5),
              Text(
                context.strings.text('active.numbers_status'),
                style: TextStyle(
                  color: Color(0xFF8998B7),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
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

  Widget _message(String value) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 30),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: const Color(0xFF718BFF).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              value == context.strings.text('active.load_error')
                  ? Icons.cloud_off_rounded
                  : Icons.sim_card_outlined,
              color: const Color(0xFF9CB4FF),
              size: 32,
            ),
          ),

          const SizedBox(height: 18),

          Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            context.strings.text('common.brand_descriptor'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF8998B7),
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
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
              context.strings.text('active.footer'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

 
Future<void> _cancel(Activation activation) async {
  if (activation.status != ActivationStatus.expired) {
    _notice(
      context.strings.text('active.cancel_only_expired'),
    );
    return;
  }

  try {
    await _activations.cancelActivation(orderId: activation.id);
    await _audit.record(
      'ACTIVATION_CANCELLED',
      success: true,
    );

    if (!mounted) return;

    _notice(context.strings.text('active.cancelled'));
  } catch (_) {
    await _audit.record(
      'ACTIVATION_CANCELLED',
      success: false,
    );

    if (!mounted) return;

    _notice(context.strings.text('active.cancel_error'));
  }
}



Future<void> _replace(Activation activation) async {
  if (activation.status != ActivationStatus.expired) {
    _notice(context.strings.text('active.replace_only_expired'));
    return;
  }

  try {
    await _activations.getAnotherNumber(
      orderId: activation.id,
      idempotencyKey: const Uuid().v4(),
    );

    await _audit.record(
      'ACTIVATION_REPLACED',
      success: true,
    );

    if (!mounted) return;

    _notice(context.strings.text('active.replacement_started'));
  } catch (_) {
    await _audit.record(
      'ACTIVATION_REPLACED',
      success: false,
    );

    if (!mounted) return;

    _notice(context.strings.text('active.replace_error'));
  }
}


  void _notice(String value) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF202B48),
          content: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
            ),
          ),
        ),
      );
  }
}
