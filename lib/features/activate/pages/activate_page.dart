import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/localization/app_localizations.dart';
import '../../../app/theme/colors.dart';
import '../../../core/services/audit_service.dart';
import '../../../core/services/catalog_repository.dart';
import '../../../core/services/catalog_bootstrap_service.dart';
import '../data/activation_repository.dart';
import '../widgets/tnum_activation_panel.dart';
import '../../../core/services/functions_service.dart';
import '../../wallet/pages/wallet_page.dart';
import '../../onboarding/first_time_app_guide.dart';

enum ActivationState { idle, finding, waiting, cancelling, received, failed }

class _ActivationPremiumBackground extends StatefulWidget {
  final Widget child;

  const _ActivationPremiumBackground({required this.child});

  @override
  State<_ActivationPremiumBackground> createState() =>
      _ActivationPremiumBackgroundState();
}

class _ActivationPremiumBackgroundState
    extends State<_ActivationPremiumBackground>
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
          right: -90,
          child: _glow(size: 280, color: const Color(0xFF5145FF)),
        ),

        Positioned(
          top: 320,
          left: -150,
          child: _glow(size: 280, color: const Color(0xFF0878F9)),
        ),

        Positioned(
          bottom: -160,
          right: -80,
          child: _glow(size: 320, color: const Color(0xFF7C3AED)),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ActivationStarsPainter(progress: _controller.value),
                );
              },
            ),
          ),
        ),

        widget.child,
      ],
    );
  }

  Widget _glow({required double size, required Color color}) {
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
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivationStarsPainter extends CustomPainter {
  final double progress;

  _ActivationStarsPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
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

      final radius = i % 9 == 0 ? 1.6 : 0.8;

      paint.color = Colors.white.withValues(alpha: opacity);

      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ActivationStarsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

// Widget build(BuildContext context) {

class ActivatePage extends StatefulWidget {
  final bool isVisible;

  const ActivatePage({super.key, required this.isVisible});

  @override
  State<ActivatePage> createState() => _ActivatePageState();
}

class _ActivatePageState extends State<ActivatePage>
    with SingleTickerProviderStateMixin {
  String? selectedService;
  String? selectedCountry;
  List<CatalogItem> _services = [];
  List<CatalogItem> _countries = [];

  ActivationState state = ActivationState.idle;

  String assignedNumber = '';
  String otpCode = '';
  String? _orderId;
  String? _idempotencyKey;
  bool _isRequesting = false;

  ActivationRepository? _activationRepository;

  int _selectedServer = 1;
  final _tnumPanel = const TnumActivationPanel(key: ValueKey('tnum-panel'));

  static const int activationDuration = 360;

  int remainingSeconds = activationDuration;
  DateTime? _activationExpiresAt;

  Timer? _timer;
  StreamSubscription<List<Map<String, dynamic>>>? _orderSubscription;

  late AnimationController _pulseController;
  bool _lastVisibility = false;
  bool _showingActivationNotice = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCatalogue();
      _handleVisibility(widget.isVisible);
    });
  }

  @override
  void didUpdateWidget(covariant ActivatePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.isVisible != widget.isVisible) {
      _handleVisibility(widget.isVisible);
    }
  }

  void _handleVisibility(bool isVisible) {
    if (!isVisible) {
      _lastVisibility = false;
      return;
    }

    if (_lastVisibility || _showingActivationNotice) return;

    _lastVisibility = true;
    _showingActivationNotice = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.isVisible) {
        _showingActivationNotice = false;
        return;
      }

      try {
        final newlyRegistered =
            await FirstTimeAppGuide.wasRegisteredOnThisInstall();
        if (!newlyRegistered) await _showActivationNotice();
        if (mounted && widget.isVisible) {
          await FirstTimeAppGuide.showIfNeeded(
            context,
            'activate',
            onStepChanged: (target) {
              final nextServer =
                  target.startsWith('T-NUM:') || target == 'NUMBER AND SMS'
                  ? 2
                  : 1;
              if (mounted && _selectedServer != nextServer) {
                setState(() => _selectedServer = nextServer);
              }
            },
          );
        }
      } finally {
        _showingActivationNotice = false;
      }
    });
  }

  Future<void> _showActivationNotice() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF172442),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: const Color(0xFF7199FF).withValues(alpha: 0.35),
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4776FF).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.info_outline_rounded,
                        color: Color(0xFF8FB6FF),
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.strings.text('activation.notice_title'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                Text(
                  context.strings.text('activation.notice_intro'),
                  style: const TextStyle(
                    color: Color(0xFFB7C6E3),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 20),

                _noticeItem(
                  '01',
                  context.strings.text('activation.notice_balance_title'),
                  context.strings.text('activation.notice_balance_message'),
                ),

                _noticeItem(
                  '02',
                  context.strings.text('activation.notice_price_title'),
                  context.strings.text('activation.notice_price_message'),
                ),

                _noticeItem(
                  '03',
                  context.strings.text('activation.notice_variable_title'),
                  context.strings.text('activation.notice_variable_message'),
                ),

                const SizedBox(height: 12),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4776FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    child: Text(
                      context.strings.text('activation.notice_button'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadCatalogue() async {
    try {
      final results = await Future.wait([
        CatalogBootstrapService.instance.vtServices,
        CatalogBootstrapService.instance.vtCountries,
      ]);
      if (!mounted) return;
      setState(() {
        _services = results[0].data;
        _countries = results[1].data;
        selectedService ??= _services.firstOrNull?.id;
        selectedCountry ??= _countries.firstOrNull?.id;
      });
    } catch (_) {
      if (mounted)
        _showMessage(
          title: context.strings.text('activation.catalog_error'),
          message: context.strings.text('activation.catalog_unavailable'),
          success: false,
        );
    }
  }

  CatalogItem? get _service =>
      _services.where((item) => item.id == selectedService).firstOrNull;
  CatalogItem? get _country =>
      _countries.where((item) => item.id == selectedCountry).firstOrNull;
  String get _serviceName =>
      _service?.name ?? context.strings.text('activation.select_service');
  String get _countryName => _country == null
      ? context.strings.text('activation.select_country')
      : _country!.name;

  @override
  void dispose() {
    _timer?.cancel();
    _orderSubscription?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  bool get isActive =>
      state == ActivationState.finding ||
      state == ActivationState.waiting ||
      state == ActivationState.cancelling ||
      state == ActivationState.received;

  String get formattedTime {
    final minutes = remainingSeconds ~/ 60;
    final seconds = remainingSeconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return _ActivationPremiumBackground(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFF111A31),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .10),
                  ),
                ),
                child: Row(
                  key: FirstTimeAppGuide.anchorKey('activate', 'VT-NUM / T-NUM'),
                  children: [
                    Expanded(child: _serverButton(1, 'SERVER 1', 'vt-num')),
                    const SizedBox(width: 6),
                    Expanded(child: _serverButton(2, 'SERVER 2', 'T-NUM')),
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedServer - 1,
                children: [
                  isActive ? _buildActiveActivation() : _buildActivationForm(),
                  FirstTimeAppGuide.anchor('activate', 'NUMBER AND SMS', _tnumPanel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverButton(int server, String title, String subtitle) {
    final selected = _selectedServer == server;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (_selectedServer == server) return;
        setState(() => _selectedServer = server);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFF4776FF), Color(0xFF7657FF)],
                )
              : null,
          color: selected ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFFA5B4D0),
                fontWeight: FontWeight.w900,
                letterSpacing: .5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                color: selected ? Colors.white70 : const Color(0xFF7D8AA7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // _buildHeader()
  // ============================================================
  // INITIAL FORM
  // ============================================================

  Widget _buildActivationForm() {
    return ListView(
      key: const ValueKey('activation-form'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 35),
      children: [
        _buildHeader(),

        const SizedBox(height: 30),

        _buildServiceSection(),

        const SizedBox(height: 24),

        _buildCountrySection(),

        const SizedBox(height: 24),

        _buildPriceCard(),

        const SizedBox(height: 24),

        _buildGetNumberButton(),
      ],
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.sim_card_rounded,
            color: Colors.white,
            size: 29,
          ),
        ),

        const SizedBox(height: 22),

        Text(
          context.strings.text('activation.title'),
          style: TextStyle(
            fontSize: 31,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
            color: Colors.white,
          ),
        ),

        const SizedBox(height: 9),

        Text(
          context.strings.text('activation.subtitle'),
          style: TextStyle(color: Color(0xFFA5B4D0), fontSize: 14, height: 1.6),
        ),

        const SizedBox(height: 17),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: const Color(0xFF10B981).withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 15,
                color: Color(0xFF34D399),
              ),
              SizedBox(width: 7),
              Text(
                context.strings.text('activation.secure'),
                style: TextStyle(
                  color: Color(0xFF6EE7B7),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  // _buildSelector()
  // ============================================================
  // SERVICE
  // ============================================================

  Widget _buildServiceSection() {
    return Column(
      key: FirstTimeAppGuide.anchorKey('activate', 'VT-NUM: SERVICE'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.strings.text('activation.service_label'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),

        const SizedBox(height: 10),

        _buildSelector(
          icon: _serviceIcon(_serviceName),
          value: _serviceName,
          onTap: _selectService,
          leadingWidget: _service == null
              ? Icon(_serviceIcon(_serviceName), color: AppColors.primary)
              : _serviceLeading(_service!),
        ),
      ],
    );
  }
  // _buildPriceCard()
  // ============================================================
  // COUNTRY
  // ============================================================

  Widget _buildCountrySection() {
    return Column(
      key: FirstTimeAppGuide.anchorKey('activate', 'VT-NUM: COUNTRY'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.strings.text('activation.country_label'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),

        const SizedBox(height: 10),

        _buildSelector(
          icon: Icons.public,
          value: _countryName,
          onTap: _selectCountry,
          leadingWidget: _country == null
              ? const Icon(Icons.public, color: AppColors.primary)
              : _countryLeading(_country!),
        ),
      ],
    );
  }

  Widget _buildSelector({
    required IconData icon,
    required String value,
    required VoidCallback onTap,
    Widget? leadingWidget,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF111A32).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF8294BD).withValues(alpha: 0.18),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF4776FF).withValues(alpha: 0.20),
                      const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Center(
                  child:
                      leadingWidget ??
                      Icon(icon, color: const Color(0xFF93B4FF)),
                ),
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      context.strings.text('activation.change_selection'),
                      style: TextStyle(color: Color(0xFF8998B7), fontSize: 11),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Color(0xFFB8C7E5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  // _buildServiceSection()
  // ============================================================
  // PRICE
  // ============================================================

  Widget _buildPriceCard() {
    return Container(
      key: FirstTimeAppGuide.anchorKey('activate', 'VT-NUM: DISPLAYED PRICE'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF182448), Color(0xFF151A35), Color(0xFF21183D)],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: const Color(0xFF8B8AFF).withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.08),
            blurRadius: 25,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFC857), Color(0xFFFF8A3D)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFA63D).withValues(alpha: 0.20),
                  blurRadius: 16,
                ),
              ],
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: Color(0xFF24172A),
              size: 28,
            ),
          ),

          const SizedBox(width: 15),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.strings.text('activation.price_title'),
                  style: TextStyle(
                    color: Color(0xFF9EACCC),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                SizedBox(height: 7),
                Text(
                  context.strings.text('activation.price_confirmed'),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  context.strings.text('activation.price_validated'),
                  style: TextStyle(
                    color: Color(0xFF9EACCC),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          const Icon(
            Icons.verified_outlined,
            color: Color(0xFF6EE7B7),
            size: 23,
          ),
        ],
      ),
    );
  }
  // _buildGetNumberButton(
  // ============================================================
  // GET NUMBER
  // ============================================================

  Widget _buildGetNumberButton() {
    final disabled =
        _isRequesting || selectedService == null || selectedCountry == null;

    return SizedBox(
      key: FirstTimeAppGuide.anchorKey('activate', 'GET NUMBER'),
      height: 60,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: disabled
              ? const LinearGradient(
                  colors: [Color(0xFF343D57), Color(0xFF343D57)],
                )
              : const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xFF4776FF),
                    Color(0xFF7657FF),
                    Color(0xFF9B5CFF),
                  ],
                ),
          borderRadius: BorderRadius.circular(19),
          boxShadow: disabled
              ? const []
              : [
                  BoxShadow(
                    color: const Color(0xFF7657FF).withValues(alpha: 0.28),
                    blurRadius: 24,
                    offset: const Offset(0, 9),
                  ),
                ],
        ),
        child: ElevatedButton(
          onPressed: disabled ? null : _requestNumber,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white54,
            shadowColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(19),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isRequesting)
                const SizedBox(
                  width: 21,
                  height: 21,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              else
                const Icon(Icons.bolt_rounded, size: 23),

              const SizedBox(width: 10),

              Flexible(
                child: Text(
                  _isRequesting
                      ? context.strings.text('activation.connecting')
                      : context.strings.text(
                          'activation.get_number',
                          variables: {'service': _serviceName.toUpperCase()},
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // ACTIVE ACTIVATION
  // ============================================================

  Widget _buildActiveActivation() {
    return ListView(
      key: const ValueKey('active-activation'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 35),
      children: [
        _buildActiveHeader(),

        const SizedBox(height: 25),

        _buildStatusCard(),

        const SizedBox(height: 18),

        // Show the received OTP immediately above the virtual number.
        if (state == ActivationState.received) ...[
          _buildOtpCard(),
          const SizedBox(height: 18),
        ],

        _buildNumberCard(),

        const SizedBox(height: 18),

        _buildCountdownCard(),

        const SizedBox(height: 25),

        if (state != ActivationState.cancelling) _buildCancelButton(),
      ],
    );
  }

  Widget _buildActiveHeader() {
    return Row(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _resetActivation,
            borderRadius: BorderRadius.circular(15),
            child: Ink(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF111A32),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: const Icon(
                Icons.arrow_back_rounded,
                size: 21,
                color: Colors.white,
              ),
            ),
          ),
        ),

        const SizedBox(width: 14),

        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('activation.title'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                ),
              ),
              SizedBox(height: 4),
              Text(
                context.strings.text('activation.live'),
                style: TextStyle(color: Color(0xFFA5B4D0), fontSize: 13),
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF10B981).withValues(alpha: 0.20),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 7, color: Color(0xFF34D399)),
              SizedBox(width: 6),
              Text(
                context.strings.text('activation.live_badge'),
                style: TextStyle(
                  color: Color(0xFF6EE7B7),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  // _buildNumberCard
  // ============================================================
  // STATUS
  // ============================================================

  Widget _noticeItem(String number, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 17),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF4776FF).withValues(alpha: 0.17),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: Color(0xFF9DBBFF),
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: const TextStyle(
                    color: Color(0xFFA5B4D0),
                    fontSize: 11,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final received = state == ActivationState.received;
    final cancelling = state == ActivationState.cancelling;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: received
              ? [
                  const Color(0xFF064E3B).withValues(alpha: 0.60),
                  const Color(0xFF111A32),
                ]
              : [const Color(0xFF1D2C56), const Color(0xFF111A32)],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: received
              ? const Color(0xFF34D399).withValues(alpha: 0.35)
              : const Color(0xFF718BFF).withValues(alpha: 0.30),
        ),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, child) {
              return Transform.scale(
                scale: received ? 1 : 0.92 + (_pulseController.value * 0.08),
                child: child,
              );
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: received
                    ? AppColors.success.withValues(alpha: 0.15)
                    : AppColors.primary.withValues(alpha: 0.15),
              ),
              child: Icon(
                received
                    ? Icons.check_circle
                    : cancelling
                    ? Icons.hourglass_top_rounded
                    : Icons.sms_outlined,
                color: received
                    ? AppColors.success
                    : cancelling
                    ? AppColors.warning
                    : AppColors.primary,
              ),
            ),
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  received
                      ? context.strings.text('activation.code_received')
                      : cancelling
                      ? context.strings.text('activation.cancelling')
                      : context.strings.text('activation.waiting_code'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .8,
                    color: received
                        ? AppColors.success
                        : cancelling
                        ? AppColors.warning
                        : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  received
                      ? context.strings.text('activation.sms_arrived')
                      : cancelling
                      ? context.strings.text('activation.cancelling_message')
                      : context.strings.text(
                          'activation.waiting_for_sms',
                          variables: {'service': _serviceName},
                        ),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  // _buildCancelButton
  // ============================================================
  // NUMBER
  // ============================================================

  Widget _buildNumberCard() {
    final isFindingNumber = state == ActivationState.finding;
    final hasNumber = assignedNumber.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF172448), Color(0xFF111A32), Color(0xFF21183D)],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(
          color: const Color(0xFF8294BD).withValues(alpha: 0.20),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 25,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            context.strings.text('activation.virtual_number'),
            style: const TextStyle(
              color: Color(0xFF9EACCC),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.3,
            ),
          ),

          const SizedBox(height: 12),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: isFindingNumber && !hasNumber
                ? Column(
                    key: const ValueKey('getting-number'),
                    children: [
                      const SizedBox(height: 8),
                      const SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.strings.text('activation.getting_number'),
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  )
                : Text(
                    assignedNumber,
                    key: const ValueKey('virtual-number'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
          ),

          const SizedBox(height: 8),

          Text(
            context.strings.text(
              'activation.country_service',
              variables: {'country': _countryName, 'service': _serviceName},
            ),
            style: const TextStyle(color: Color(0xFFA5B4D0), fontSize: 13),
          ),

          const SizedBox(height: 18),

          OutlinedButton.icon(
            onPressed: hasNumber
                ? () {
                    Clipboard.setData(ClipboardData(text: assignedNumber));

                    _showMessage(
                      title: context.strings.text('common.copied'),
                      message: context.strings.text('activation.number_copied'),
                      success: true,
                    );
                  }
                : null,
            icon: const Icon(Icons.copy, size: 17),
            label: Text(context.strings.text('activation.copy_number')),
          ),
        ],
      ),
    );
  }

  // _buildCountdownCard
  // ============================================================
  // COUNTDOWN
  // ============================================================

  Widget _buildCountdownCard() {
    final progress = remainingSeconds / _ActivatePageState.activationDuration;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: const Color(0xFF8294BD).withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        children: [
          Text(
            context.strings.text('activation.time_remaining'),
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),

          const SizedBox(height: 12),

          Text(
            formattedTime,
            style: const TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),

          const SizedBox(height: 16),

          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
  // _buildStatusCard
  // ============================================================
  // OTP
  // ============================================================

  Widget _buildOtpCard() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (_, value, child) {
        return Transform.scale(scale: value, child: child);
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.success, Color(0xFF16A34A)],
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            const Icon(Icons.mark_email_read, size: 34),

            const SizedBox(height: 10),

            Text(
              context.strings.text('activation.verification_code'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),

            const SizedBox(height: 10),

            Text(
              otpCode,
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w900,
                letterSpacing: 8,
              ),
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _copyOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.success,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                icon: const Icon(Icons.copy),
                label: Text(
                  context.strings.text('activation.copy_code'),
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // CANCEL
  // ============================================================

  Widget _buildCancelButton() {
    return SizedBox(
      height: 54,
      child: OutlinedButton.icon(
        onPressed: _confirmCancel,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF7B8B),
          side: BorderSide(
            color: const Color(0xFFFF647C).withValues(alpha: 0.35),
          ),
          backgroundColor: const Color(0xFFFF647C).withValues(alpha: 0.06),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        ),
        icon: const Icon(Icons.close_rounded, size: 19),
        label: Text(
          context.strings.text('activation.cancel'),
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
        ),
      ),
    );
  }
  // _showCatalogueSheet
  // REQUEST
  // ============================================================

  Future<void> _requestNumber() async {
    if (_isRequesting || selectedService == null || selectedCountry == null)
      return;

    setState(() {
      _isRequesting = true;
      state = ActivationState.finding;
    });

    try {
      final result = await (_activationRepository ??= ActivationRepository())
          .requestActivation(
            serviceId: selectedService!,
            countryId: selectedCountry!,
            idempotencyKey: _idempotencyKey ??= const Uuid().v4(),
          );

      if (!mounted) return;

      final phoneNumber = result['phoneNumber'];
      final orderId = result['orderId'];
      final expiresAt = result['expiresAt'] is String
          ? DateTime.tryParse(result['expiresAt'] as String)?.toLocal()
          : null;

      if (phoneNumber is! String || orderId is! String) {
        throw StateError(
          context.strings.text('activation.invalid_server_response'),
        );
      }

      setState(() {
        _orderId = orderId;
        assignedNumber = phoneNumber;
        state = ActivationState.waiting;
        _activationExpiresAt = expiresAt;
        remainingSeconds = expiresAt == null
            ? activationDuration
            : expiresAt
                  .difference(DateTime.now())
                  .inSeconds
                  .clamp(0, activationDuration)
                  .toInt();
      });

      _startCountdown();
      _watchOrder(orderId);
      await AuditService().record('ACTIVATION_REQUESTED', success: true);
   
    } catch (error) {
      await AuditService().record('ACTIVATION_REQUESTED', success: false);
      if (!mounted) return;

      setState(() {
        state = ActivationState.idle;
        _idempotencyKey = null;
      });

      final errorMessage = error.toString();
      final isNoNumbersAvailable =
          errorMessage.contains('NO_NUMBERS_AVAILABLE');

      final isInsufficientBalance =
          error is FunctionsException &&
          const ['INSUFFICIENT_BALANCE', 'INSUFFICIENT_FUNDS']
              .contains(error.code);

      if (isInsufficientBalance) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              context.strings.text('activation.insufficient_balance_title'),
            ),
            content: Text(
              context.strings.text('activation.insufficient_balance_message'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.strings.text('common.cancel')),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const WalletPage(
                        openTopUpOnStart: true,
                      ),
                    ),
                  );
                },
                child: Text(context.strings.text('wallet.add_funds')),
              ),
            ],
          ),
        );
      } else {
        _showMessage(
          title: context.strings.text('activation.number_unavailable'),
          message: isNoNumbersAvailable
              ? context.strings.text('activation.no_number_message')
              : errorMessage,
          success: false,
        );
      }
    }
 finally {
      if (mounted) {
        setState(() {
          _isRequesting = false;
        });
      }
  }
  }

  void _startCountdown() {
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final deadline = _activationExpiresAt;
      final remaining = deadline == null
          ? remainingSeconds - 1
          : deadline
                .difference(DateTime.now())
                .inSeconds
                .clamp(0, activationDuration)
                .toInt();

      if (remaining <= 0) {
        timer.cancel();

        setState(() {
          remainingSeconds = 0;
        });

        _showMessage(
          title: context.strings.text('activation.expired'),
          message: context.strings.text('activation.code_timeout'),
          success: false,
        );

        return;
      }

      setState(() {
        remainingSeconds = remaining;
      });
    });
  }

  void _watchOrder(String orderId) {
    _orderSubscription?.cancel();
    _orderSubscription = Supabase.instance.client
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('id', orderId)
        .listen((rows) {
          if (!mounted || rows.isEmpty) return;
          final data = rows.first;
          final status = data['status'] as String?;
          final code = data['code'] as String?;
          final expiresAt = data['expires_at'] == null
              ? null
              : DateTime.tryParse(data['expires_at'].toString());
          setState(() {
            if (expiresAt != null) {
              _activationExpiresAt = expiresAt.toLocal();
              remainingSeconds = expiresAt
                  .difference(DateTime.now())
                  .inSeconds
                  .clamp(0, activationDuration)
                  .toInt();
            }
            if (code != null && code.isNotEmpty) {
              otpCode = code;
              state = ActivationState.received;
              _timer?.cancel();
            } else if (status == 'CANCELLING') {
              state = ActivationState.cancelling;
              _timer?.cancel();
            }
            if (status == 'EXPIRED' ||
                status == 'CANCELLED' ||
                status == 'FAILED') {
              state = ActivationState.failed;
              _timer?.cancel();
            }
          });
        });
  }

  void _copyOtp() {
    Clipboard.setData(ClipboardData(text: otpCode));

    _showMessage(
      title: context.strings.text('common.copied'),
      message: context.strings.text('activation.code_copied'),
      success: true,
    );
  }

  // ============================================================
  // CANCEL
  // ============================================================

  Future<void> _confirmCancel() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(context.strings.text('activation.cancel_confirm_title')),
          content: Text(
            context.strings.text('activation.cancel_confirm_message'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.text('common.keep')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                context.strings.text('common.cancel'),
                style: TextStyle(color: AppColors.error),
              ),
            ),
          ],
        );
      },
    );

    if (result == true) {
      if (_orderId != null) {
        try {
          await (_activationRepository ??= ActivationRepository())
              .cancelActivation(orderId: _orderId!);

          if (!mounted) return;
          _showMessage(
            title: context.strings.text('activation.cancel_requested'),
            message: context.strings.text('activation.cancel_sent'),
            success: true,
          );
        } catch (error) {
          if (!mounted) return;
          _showMessage(
            title: context.strings.text('activation.cancel_failed'),
            message: error.toString(),
            success: false,
          );
        }
        return;
      }

      _resetActivation();
    }
  }

  void _resetActivation() {
    _timer?.cancel();
    _orderSubscription?.cancel();
    _orderSubscription = null;

    setState(() {
      state = ActivationState.idle;
      _orderId = null;
      _idempotencyKey = null;
      assignedNumber = '';
      otpCode = '';
      remainingSeconds = activationDuration;
      _activationExpiresAt = null;
    });
  }

  // ============================================================
  // SERVICE SELECTION
  // ============================================================

  void _selectService() {
    _showCatalogueSheet(
      title: context.strings.text('activation.choose_service'),
      items: _services,
      selectedId: selectedService,
      onSelected: (item) => setState(() => selectedService = item.id),
    );
  }

  void _selectCountry() {
    _showCatalogueSheet(
      title: context.strings.text('activation.choose_country'),
      items: _countries,
      selectedId: selectedCountry,
      onSelected: (item) => setState(() => selectedCountry = item.id),
    );
  }

  void _showCatalogueSheet({
    required String title,
    required List<CatalogItem> items,
    required String? selectedId,
    required ValueChanged<CatalogItem> onSelected,
  }) {
    String searchQuery = '';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1428),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final filteredItems = items.where((item) {
            return item.name.toLowerCase().contains(
              searchQuery.trim().toLowerCase(),
            );
          }).toList();

          final isService = title.toLowerCase().contains('service');

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.75,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          autofocus: false,
                          onChanged: (value) {
                            setSheetState(() => searchQuery = value);
                          },
                          decoration: InputDecoration(
                            hintText: isService
                                ? context.strings.text(
                                    'activation.search_service',
                                  )
                                : context.strings.text(
                                    'activation.search_country',
                                  ),
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            fillColor: AppColors.background,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: filteredItems.isEmpty
                        ? Center(
                            child: Text(
                              context.strings.text('activation.no_results'),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                            itemCount: filteredItems.length,
                            itemBuilder: (context, index) {
                              final item = filteredItems[index];
                              final selected = item.id == selectedId;
                              // leading

                              return ListTile(
                                leading: isService
                                    ? _serviceLeading(item)
                                    : _countryLeading(item),
                                title: Text(item.name),
                                selected: selected,
                                trailing: selected
                                    ? const Icon(
                                        Icons.check_circle,
                                        color: AppColors.primary,
                                      )
                                    : null,
                                onTap: () {
                                  onSelected(item);
                                  Navigator.pop(sheetContext);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String? _serviceLogoUrl(CatalogItem item) {
    final raw = item.flag.trim();
    final uri = Uri.tryParse(raw);

    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      return raw;
    }

    return null;
  }

  Widget _serviceLeading(CatalogItem item) {
    final url = _serviceLogoUrl(item);

    if (url == null) {
      return CircleAvatar(child: Icon(_serviceIcon(item.name)));
    }

    final isSvg = Uri.parse(url).path.toLowerCase().endsWith('.svg');

    return CircleAvatar(
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: isSvg
            ? SvgPicture.network(
                url,
                fit: BoxFit.contain,
                placeholderBuilder: (_) => const Icon(Icons.apps),
              )
            : Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Icon(_serviceIcon(item.name)),
              ),
      ),
    );
  }

  Widget _countryLeading(CatalogItem item) {
    final flag = item.flag.trim();
    final uri = Uri.tryParse(flag);

    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      final isSvg = uri.path.toLowerCase().endsWith('.svg');

      return SizedBox(
        width: 36,
        height: 30,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: isSvg
                ? SvgPicture.network(
                    flag,
                    width: 30,
                    height: 22,
                    fit: BoxFit.contain,
                    placeholderBuilder: (_) => const Icon(Icons.flag_outlined),
                  )
                : Image.network(
                    flag,
                    width: 30,
                    height: 22,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.flag_outlined),
                  ),
          ),
        ),
      );
    }

    // Compatibilité avec les anciens drapeaux enregistrés en emoji.
    if (flag.isNotEmpty && !flag.startsWith('http')) {
      return SizedBox(
        width: 36,
        child: Center(child: Text(flag, style: const TextStyle(fontSize: 25))),
      );
    }

    return const SizedBox(
      width: 36,
      height: 30,
      child: Center(child: Icon(Icons.public)),
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  IconData _serviceIcon(String service) {
    switch (service.trim().toLowerCase()) {
      case 'telegram':
        return Icons.send;

      case 'instagram':
        return Icons.camera_alt_outlined;

      case 'facebook':
        return Icons.facebook;

      case 'tiktok':
        return Icons.music_note;

      case 'whatsapp':
        return Icons.chat;

      case 'gmail':
      case 'google':
        return Icons.mail_outline;

      case 'snapchat':
        return Icons.camera_alt;

      case 'discord':
        return Icons.forum_outlined;

      case 'x':
      case 'twitter':
        return Icons.alternate_email;

      case 'youtube':
        return Icons.play_circle_outline;

      default:
        return Icons.apps;
    }
  }

  void _showMessage({
    required String title,
    required String message,
    required bool success,
  }) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Row(
            children: [
              Icon(
                success ? Icons.check_circle : Icons.error,
                color: success ? AppColors.success : AppColors.error,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title)),
            ],
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.strings.text('common.confirm')),
            ),
          ],
        );
      },
    );
  }
}
