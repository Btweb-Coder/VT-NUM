import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../app/theme/colors.dart';
import '../../app/localization/app_localizations.dart';
import '../../core/models/order.dart';
import '../../core/services/catalog_repository.dart';
import '../../core/services/order_repository.dart';
import '../../core/services/wallet_repository.dart';
import '../../core/services/catalog_bootstrap_service.dart';
import '../onboarding/first_time_app_guide.dart';

// ============================================================
// VT NUM — FOND PREMIUM ANIMÉ
// ============================================================

class _HomePremiumBackground extends StatefulWidget {
  const _HomePremiumBackground({required this.child});

  final Widget child;

  @override
  State<_HomePremiumBackground> createState() => _HomePremiumBackgroundState();
}

class _HomePremiumBackgroundState extends State<_HomePremiumBackground>
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
                Color(0xFF050817),
                Color(0xFF0C1530),
                Color(0xFF10112B),
                Color(0xFF050817),
              ],
            ),
          ),
        ),

        Positioned(
          top: -110,
          right: -120,
          child: _homeGlow(size: 300, color: const Color(0xFF3478F6)),
        ),

        Positioned(
          top: 360,
          left: -170,
          child: _homeGlow(size: 280, color: const Color(0xFF7845E8)),
        ),

        Positioned(
          bottom: -170,
          right: -100,
          child: _homeGlow(size: 320, color: const Color(0xFF2467D9)),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _HomeStarsPainter(_controller.value),
                );
              },
            ),
          ),
        ),

        widget.child,
      ],
    );
  }

  Widget _homeGlow({required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.08),
      ),
    );
  }
}

class _HomeStarsPainter extends CustomPainter {
  _HomeStarsPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(82);

    for (var i = 0; i < 75; i++) {
      final baseX = random.nextDouble() * size.width;
      final baseY = random.nextDouble() * size.height;
      final phase = random.nextDouble() * math.pi * 2;
      final speed = 0.35 + random.nextDouble() * 0.8;
      final radius = 0.5 + random.nextDouble() * 1.2;

      final y = ((baseY / size.height + progress * speed) % 1.0) * size.height;

      final x = baseX + math.sin(progress * math.pi * 2 + phase) * 9;

      final opacity =
          (0.15 +
                  0.55 *
                      (0.5 +
                          0.5 *
                              math.sin(progress * math.pi * 2 * speed + phase)))
              .clamp(0.0, 1.0);

      final paint = Paint()
        ..color = Color.fromRGBO(210, 227, 255, opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), radius, paint);

      if (i % 13 == 0) {
        final glow = Paint()
          ..color = const Color(0xFF6CA6FF).withValues(alpha: opacity * 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

        canvas.drawCircle(Offset(x, y), radius * 3, glow);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HomeStarsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class HomePage extends StatefulWidget {
  final VoidCallback? onOpenActivation;
  final VoidCallback? onOpenActive;
  final VoidCallback? onOpenWalletTopUp;

  const HomePage({
    super.key,
    this.onOpenActivation,
    this.onOpenActive,
    this.onOpenWalletTopUp,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<CatalogItem>> _servicesFuture;
  late Stream<WalletSnapshot?> _walletStream;
  late Stream<List<Order>> _ordersStream;

  bool _isRefreshing = false;
  final ScrollController _guideScrollController = ScrollController();

  // Dernières données reçues avec succès.
  // Elles servent uniquement à conserver l'affichage pendant une erreur réseau.
  WalletSnapshot? _lastWallet;
  List<Order>? _lastOrders;

  static const Set<String> _activeStatuses = {'WAITING_FOR_SMS'};

  @override
  void initState() {
    super.initState();

    FirstTimeAppGuide.registerReveal('home', () {
      if (_guideScrollController.hasClients) {
        _guideScrollController.animateTo(
          _guideScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });

    _servicesFuture = CatalogBootstrapService.instance.vtServices.then(
      (r) => r.data,
    );
    _walletStream = WalletRepository().watchWallet();
    _ordersStream = OrderRepository().watchOrders();
  }

  @override
  void dispose() {
    FirstTimeAppGuide.unregisterReveal('home');
    _guideScrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshDashboard() async {
    if (_isRefreshing) return;

    setState(() {
      _isRefreshing = true;
    });

    try {
      final servicesFuture = CatalogBootstrapService.instance.vtServices.then(
        (r) => r.data,
      );

      setState(() {
        _servicesFuture = servicesFuture;
        _walletStream = WalletRepository().watchWallet();
        _ordersStream = OrderRepository().watchOrders();
      });

      await servicesFuture;
    } catch (e) {
      debugPrint('Erreur actualisation dashboard : $e');
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _HomePremiumBackground(
      child: SafeArea(
        child: CustomScrollView(
          controller: _guideScrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _buildHeader(),
                  const SizedBox(height: 25),

                  FirstTimeAppGuide.anchor('home', 'AVAILABLE BALANCE', _balanceCard()),
                  const SizedBox(height: 16),

                  _refreshDashboardButton(),

                  const SizedBox(height: 30),

                  Text(
                    context.strings.text('home.quick_activation'),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    context.strings.text('home.quick_subtitle'),
                    style: TextStyle(color: Color(0xFF95A7CC), fontSize: 13),
                  ),
                  const SizedBox(height: 17),

                  FirstTimeAppGuide.anchor('home', 'QUICK SERVICES', _quickServices()),

                  const SizedBox(height: 30),

                  _sectionHeader(
                    title: context.strings.text('home.active_activations'),
                    action: context.strings.text('home.view_all'),
                    onTap: widget.onOpenActive ?? () {},
                  ),
                  const SizedBox(height: 12),

                  FirstTimeAppGuide.anchor('home', 'ACTIVE ACTIVATIONS', _activeOrders()),

                  const SizedBox(height: 30),

                  Text(
                    context.strings.text('home.recent_activity'),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    context.strings.text('home.recent_subtitle'),
                    style: TextStyle(color: Color(0xFF95A7CC), fontSize: 13),
                  ),
                  const SizedBox(height: 17),

                  FirstTimeAppGuide.anchor('home', 'RECENT ACTIVITY', _recentOrders()),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _refreshDashboardButton() {
    return SizedBox(
      width: double.infinity,
      height: 68,
      child: ElevatedButton(
        onPressed: _isRefreshing ? null : _refreshDashboard,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2563EB),
          disabledBackgroundColor: const Color(0xFF33466F),
          foregroundColor: Colors.white,
          elevation: 8,
          shadowColor: const Color(0xFF3478F6).withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(19),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isRefreshing)
              const SizedBox(
                width: 25,
                height: 25,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            else
              const Icon(Icons.refresh_rounded, size: 29),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                _isRefreshing
                    ? 'ACTUALISATION EN COURS...'
                    : 'ACTUALISER LE TABLEAU DE BORD',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final activeLanguage = Localizations.localeOf(
      context,
    ).languageCode.toUpperCase();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 55,
          height: 55,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF579BFF), Color(0xFF6549E8)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3478F6).withValues(alpha: 0.25),
                blurRadius: 20,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 32),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('home.welcome_back'),
                style: const TextStyle(
                  color: Color(0xFF8FB6FF),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                context.strings.text('home.dashboard'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.strings.text('home.tagline'),
                style: const TextStyle(color: Color(0xFF95A7CC), fontSize: 12),
              ),
            ],
          ),
        ),

        PopupMenuButton<String>(
          tooltip: context.strings.text('language.change'),
          onSelected: (language) {
            AppLocaleScope.controllerOf(context).setLocale(Locale(language));
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'fr',
              child: Row(
                children: [
                  const Text('🇫🇷'),
                  const SizedBox(width: 10),
                  Text(context.strings.text('language.french')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'en',
              child: Row(
                children: [
                  const Text('🇬🇧'),
                  const SizedBox(width: 10),
                  Text(context.strings.text('language.english')),
                ],
              ),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF182747).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: const Color(0xFF8FB6FF).withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.language_rounded,
                  color: Colors.white,
                  size: 21,
                ),
                const SizedBox(width: 7),
                Text(
                  activeLanguage,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(width: 3),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Color(0xFF95A7CC),
                  size: 17,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _balanceCard() {
    return StreamBuilder<WalletSnapshot?>(
      stream: _walletStream,
      builder: (context, snapshot) {
        // Mémoriser chaque valeur reçue, même si elle est null.
        if (snapshot.hasData) {
          _lastWallet = snapshot.data;
        }

        // Si le flux rencontre une erreur, conserver le dernier solde connu.
        if (snapshot.hasError) {
          final wallet = _lastWallet;

          if (wallet != null) {
            return _balanceCardContent(
              balanceText: wallet.available.toStringAsFixed(2),
              currency: wallet.currency,
              message: context.strings.text('home.balance_stale'),
            );
          }

          return _balanceCardContent(
            balanceText: context.strings.text('common.unavailable'),
            currency: '',
            message: context.strings.text('home.balance_load_error'),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          final wallet = _lastWallet;

          if (wallet != null) {
            return _balanceCardContent(
              balanceText: wallet.available.toStringAsFixed(2),
              currency: wallet.currency,
              message: context.strings.text('home.balance_stale'),
            );
          }

          return _balanceCardContent(
            balanceText: '...',
            currency: '',
            message: context.strings.text('home.balance_loading'),
          );
        }

        final wallet = snapshot.hasData ? snapshot.data : _lastWallet;

        if (wallet == null) {
          return _balanceCardContent(
            balanceText: '--',
            currency: '',
            message: context.strings.text('home.wallet_initializing'),
          );
        }

        return _balanceCardContent(
          balanceText: wallet.available.toStringAsFixed(2),
          currency: wallet.currency,
          message: context.strings.text('home.activation_ready'),
        );
      },
    );
  }

  Widget _balanceCardContent({
    required String balanceText,
    required String currency,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(23),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(27),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF346EEA), Color(0xFF5147D9), Color(0xFF703FC3)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF426BFF).withValues(alpha: 0.23),
            blurRadius: 28,
            offset: const Offset(0, 13),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: -40,
            right: -35,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.055),
              ),
            ),
          ),
          Positioned(
            top: 20,
            right: 12,
            child: Icon(
              Icons.account_balance_wallet_rounded,
              size: 65,
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.wallet_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Text(
                    context.strings.text('home.my_wallet'),
                    style: TextStyle(
                      color: Color(0xFFDCE7FF),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 25),
              Text(
                context.strings.text('wallet.available_balance'),
                style: TextStyle(
                  color: Color(0xFFDCE5FF),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      currency.isEmpty ? balanceText : '$balanceText $currency',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 29,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: -0.8,
                      ),
                    ),
                  ),
                  if (widget.onOpenWalletTopUp != null) ...[
                    const SizedBox(width: 8),
                    FirstTimeAppGuide.anchor('home', 'ADD FUNDS', OutlinedButton.icon(
                      onPressed: widget.onOpenWalletTopUp,
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: Text(
                        context.strings.text('wallet.add_funds'),
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.13),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    )),
                  ],
                ],
              ),
              const SizedBox(height: 23),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    )),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickServices() {
    return FutureBuilder<List<CatalogItem>>(
      future: _servicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return _messageCard(
            'Impossible de charger les services.',
            icon: Icons.error_outline,
          );
        }

        final services = (snapshot.data ?? []).where((service) {
          final name = service.name.toLowerCase().trim();
          return name == 'whatsapp' || name == 'telegram';
        }).toList();

        if (services.isEmpty) {
          return _messageCard(
            'Aucun service actif disponible pour le moment.',
            icon: Icons.phone_android,
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 500 ? 3 : 2;
            final itemWidth =
                (constraints.maxWidth - (12 * (columns - 1))) / columns;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: services.map((service) {
                return SizedBox(width: itemWidth, child: _serviceCard(service));
              }).toList(),
            );
          },
        );
      },
    );
  }

  Widget _serviceCard(CatalogItem service) {
    final name = service.name.toLowerCase();

    final IconData icon = name.contains('whatsapp')
        ? Icons.chat_rounded
        : name.contains('telegram')
        ? Icons.send_rounded
        : Icons.phone_android_rounded;

    final Color accent = name.contains('whatsapp')
        ? const Color(0xFF4ADE80)
        : name.contains('telegram')
        ? const Color(0xFF62B7FF)
        : const Color(0xFF8EABFF);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onOpenActivation,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            color: const Color(0xFF121C35).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: accent.withValues(alpha: 0.23)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 49,
                height: 49,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withValues(alpha: 0.20)),
                ),
                child: Icon(icon, size: 26, color: accent),
              ),
              const SizedBox(height: 17),
              Text(
                service.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.strings.text('home.discover_service'),
                      style: TextStyle(color: Color(0xFF9AADD0), fontSize: 10),
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: Color(0xFFB9CAEA),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required String title,
    required String action,
    required VoidCallback onTap,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF8EB7FF),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                action,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_ios_rounded, size: 12),
            ],
          ),
        ),
      ],
    );
  }

  Widget _activeOrders() {
    return StreamBuilder<List<Order>>(
      stream: _ordersStream,
      builder: (context, snapshot) {
        // Conserver la dernière liste reçue avec succès.
        if (snapshot.hasData) {
          _lastOrders = snapshot.data;
        }

        // Une erreur ne doit pas effacer une liste déjà chargée.
        if (snapshot.hasError && _lastOrders == null) {
          return _messageCard(
            'Impossible de charger les activations.',
            icon: Icons.error_outline,
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData &&
            _lastOrders == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          );
        }

        final orders =
            (snapshot.hasData ? snapshot.data : _lastOrders ?? <Order>[])
                ?.where(
                  (order) =>
                      order.replacementOrderId == null &&
                      !order.wasReplaced &&
                      _activeStatuses.contains(order.rawStatus),
                )
                .toList() ??
            <Order>[];

        if (orders.isEmpty) {
          return _messageCard(
            context.strings.text('home.no_active_activations'),
            icon: Icons.hourglass_empty,
          );
        }

        return Column(
          children: [
            _summaryCard(
              icon: Icons.bolt,
              title: context.strings.text('home.active_activations'),
              subtitle: context.strings.text(
                orders.length == 1
                    ? 'home.activation_count_one'
                    : 'home.activation_count_many',
                variables: {'count': orders.length},
              ),
              color: AppColors.primary,
            ),
            const SizedBox(height: 10),
            ...orders.take(2).map(_orderCard),
          ],
        );
      },
    );
  }

  Widget _recentOrders() {
    return StreamBuilder<List<Order>>(
      stream: _ordersStream,
      builder: (context, snapshot) {
        // Conserver la dernière liste reçue avec succès.
        if (snapshot.hasData) {
          _lastOrders = snapshot.data;
        }

        if (snapshot.hasError && _lastOrders == null) {
          return _messageCard(
            'Impossible de charger l’activité récente.',
            icon: Icons.error_outline,
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData &&
            _lastOrders == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          );
        }

        final orders =
            (snapshot.hasData ? snapshot.data : _lastOrders ?? <Order>[])
                ?.take(3)
                .toList() ??
            <Order>[];

        if (orders.isEmpty) {
          return _messageCard(
            'Aucune activité pour le moment.',
            icon: Icons.history,
          );
        }

        return Column(children: orders.map(_orderCard).toList());
      },
    );
  }

  Widget _orderCard(Order order) {
    final status = _statusLabel(order);
    final color = _statusColor(order);

    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF111B33).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white.withValues(alpha: 0.075)),
      ),
      child: Row(
        children: [
          Container(
            width: 45,
            height: 45,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.receipt_long_rounded, color: color, size: 23),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.service.isEmpty
                      ? context.strings.text('home.activation')
                      : order.service,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  context.strings.text(
                    'home.recent_order_item',
                    variables: {
                      'phone': order.phoneNumber.isEmpty
                          ? context.strings.text('home.number_unavailable')
                          : order.phoneNumber,
                      'date': _formatDate(order.createdAt),
                    },
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF94A6C9),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.16), const Color(0xFF121C35)],
        ),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, size: 26, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFA4B5D5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios_rounded, color: color, size: 15),
        ],
      ),
    );
  }

  Widget _messageCard(String message, {required IconData icon}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xFF111B33).withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Colors.white.withValues(alpha: 0.075)),
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: const Color(0xFF719CFF).withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 29, color: const Color(0xFF92B5FF)),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFA9B9D7),
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(Order order) {
    if (order.replacementOrderId != null) return 'Remplacée';

    return switch (order.rawStatus) {
      'PROVIDER_REQUESTING' => 'Recherche',
      'WAITING_FOR_SMS' => 'En attente',
      'SMS_RECEIVED' || 'COMPLETED' => 'Terminée',
      'EXPIRING' => 'Expiration',
      'CANCELLING' => 'Annulation',
      'EXPIRED' => 'Expirée',
      'CANCELLED' || 'CANCELED' => 'Annulée',
      'FAILED' => 'Échec',
      'REFUNDED' => 'Remboursée',
      'REPLACING' => 'Remplacement',
      _ => order.rawStatus,
    };
  }

  Color _statusColor(Order order) {
    if (order.replacementOrderId != null) return AppColors.textMuted;

    return switch (order.rawStatus) {
      'SMS_RECEIVED' || 'COMPLETED' => AppColors.success,
      'FAILED' || 'EXPIRED' || 'CANCELLED' || 'CANCELED' => AppColors.textMuted,
      _ => AppColors.primary,
    };
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '$day/$month ${hour}h$minute';
  }
}

// Widget _buildHeader() {
