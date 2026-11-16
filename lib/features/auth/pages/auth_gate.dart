import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'terms_conditions_page.dart';
import '../../../app/localization/app_localizations.dart';
import '../../../app/router.dart';
import '../../../app/theme/colors.dart';
import '../../../core/services/auth_service.dart';

enum _AlertType { success, error, info }

Future<void> _showSweetAlert(
  BuildContext context, {
  required String title,
  required String message,
  required _AlertType type,
  String? buttonText,
}) async {
  final Color color;
  final IconData icon;

  switch (type) {
    case _AlertType.success:
      color = const Color(0xFF16A36A);
      icon = Icons.check_rounded;
    case _AlertType.error:
      color = const Color(0xFFE5484D);
      icon = Icons.close_rounded;
    case _AlertType.info:
      color = const Color(0xFF3478F6);
      icon = Icons.mail_outline_rounded;
  }

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: context.strings.text('auth.alert'),
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
            decoration: BoxDecoration(
              color: Theme.of(dialogContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.35, end: 1),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) {
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: Container(
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.12),
                      border: Border.all(color: color, width: 3),
                    ),
                    child: Icon(icon, color: color, size: 48),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.55,
                    color: Theme.of(dialogContext).textTheme.bodyMedium?.color,
                  ),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(
                      buttonText ?? context.strings.text('auth.ok'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );

      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: curved, child: child),
      );
    },
  );
}

String _friendlyAuthError(BuildContext context, AuthException error) {
  final message = error.message.toLowerCase();

  if (message == 'email_not_verified') {
    return context.strings.text('auth.email_not_verified');
  }

  if (message == 'account_creation_incomplete') {
    return context.strings.text('auth.unexpected_connection_error');
  }

  // Adresse e-mail déjà utilisée.
  if (message == 'email_already_registered' ||
      message.contains('already registered') ||
      message.contains('already exists') ||
      message.contains('already been registered')) {
    return context.strings.text('auth.errors.email_already_registered');
  }

  if (message.contains('INVALID_OR_UNAVAILABLE_REFERRAL_CODE')) {
    return context.strings.text('referral.invalid_code');
  }

  if (message.contains('password')) {
    return context.strings.text('auth.errors.password_requirements');
  }

  if (message.contains('invalid email')) {
    return context.strings.text('auth.errors.invalid_email');
  }

  if (message.contains('rate limit') ||
      message.contains('too many requests')) {
    return context.strings.text('auth.errors.rate_limit');
  }

  if (message.contains('network') || message.contains('socket')) {
    return context.strings.text('auth.errors.network');
  }

  return error.message;
}

class AuthGate extends StatefulWidget {
  AuthGate({super.key, AuthService? authService})
    : authService = authService ?? AuthService();

  final AuthService authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;

  User? _user;
  bool _initialStateReceived = false;
  bool _passwordRecovery = false;

  @override
  void initState() {
    super.initState();

    _authSubscription = widget.authService.authStateChanges.listen(
      (state) {
        if (!mounted) return;

        // A confirmed session created by the email callback must not open the app.
        // Only accept signedIn events initiated by the manual email/password form.
        if (state.event == AuthChangeEvent.signedIn &&
            state.session?.user.emailConfirmedAt != null &&
            !widget.authService.isManualSignInInProgress) {
          setState(() {
            _initialStateReceived = true;
            _user = null;
            _passwordRecovery = false;
          });
          unawaited(widget.authService.signOut());
          return;
        }

        setState(() {
          _initialStateReceived = true;
          _user = state.session?.user;

          if (state.event == AuthChangeEvent.passwordRecovery) {
            _passwordRecovery = true;
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  void _finishPasswordRecovery() {
    if (!mounted) return;

    setState(() {
      _passwordRecovery = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialStateReceived) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_passwordRecovery) {
      return ResetPasswordPage(
        authService: widget.authService,
        onCompleted: _finishPasswordRecovery,
      );
    }

    final user = _user;

    if (user == null) {
      return SignInPage(authService: widget.authService);
    }

    return user.emailConfirmedAt != null
        ? const AppRouter()
        : VerificationPage(authService: widget.authService);
  }
}

class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key, required this.authService});

  final AuthService authService;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  bool _working = false;

  Future<void> _run(
    Future<void> Function() action, {
    required String successTitle,
    required String successMessage,
  }) async {
    if (_working) return;

    setState(() => _working = true);

    try {
      await action();

      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: successTitle,
        message: successMessage,
        type: _AlertType.success,
      );
    } on AuthException catch (error) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('common.error'),
        message: _friendlyAuthError(context, error),
        type: _AlertType.error,
      );
    } catch (_) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('auth.login_error'),
        message: context.strings.text('auth.unexpected_connection_error'),
        type: _AlertType.error,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.mark_email_read_outlined,
                  size: 64,
                  color: AppColors.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  context.strings.text('auth.verify_email_title'),
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  context.strings.text('auth.verify_email_body'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _working
                        ? null
                        : () => _run(
                            () async {
                              final verified = await widget.authService
                                  .refreshVerification();

                              if (!verified) {
                                throw const AuthException('email_not_verified');
                              }
                            },
                            successTitle: context.strings.text('auth.email_verified'),
                            successMessage: context.strings.text('auth.email_verified_message'),
                          ),
                    child: _working
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(context.strings.text('auth.verified_button')),
                  ),
                ),
                TextButton(
                  onPressed: _working
                      ? null
                      : () => _run(
                          widget.authService.resendVerification,
                          successTitle: context.strings.text('auth.resend_requested'),
                          successMessage: context.strings.text('auth.resend_confirmation_message'),
                        ),
                  child: Text(context.strings.text('auth.resend_email')),
                ),
                TextButton(
                  onPressed: _working
                      ? null
                      : () async {
                          try {
                            await widget.authService.signOut();
                          } catch (_) {
                            if (!context.mounted) return;

                            await _showSweetAlert(
                              context,
                              title: context.strings.text('auth.logout_error'),
                              message: context.strings.text('common.retry'),
                              type: _AlertType.error,
                            );
                          }
                        },
                  child: Text(context.strings.text('auth.sign_out')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({
    super.key,
    required this.authService,
    required this.onCompleted,
  });

  final AuthService authService;
  final VoidCallback onCompleted;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _submitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);

    try {
      await widget.authService.updatePassword(
        _passwordController.text,
      );

      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('auth.password_changed'),
        message: context.strings.text('auth.password_saved'),
        type: _AlertType.success,
      );

      if (!mounted) return;

      await widget.authService.signOut();

      if (!mounted) return;

      widget.onCompleted();
    } on AuthException catch (error) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('auth.update_failed'),
        message: _friendlyAuthError(context, error),
        type: _AlertType.error,
        buttonText: context.strings.text('common.retry'),
      );
    } catch (_) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('common.error'),
        message: context.strings.text('auth.password_update_error'),
        type: _AlertType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.lock_reset_rounded,
                    size: 72,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    context.strings.text('auth.new_password'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.strings.text('auth.choose_password_help'),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    enabled: !_submitting,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: context.strings.text('auth.new_password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: _submitting
                            ? null
                            : () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return context.strings.text('auth.new_password_required');
                      }

                      if (value.length < 8) {
                        return context.strings.text('auth.password_min_length');
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _confirmPasswordController,
                    obscureText: _obscureConfirmation,
                    enabled: !_submitting,
                    decoration: InputDecoration(
                      labelText: context.strings.text('auth.confirm_password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: _submitting
                            ? null
                            : () {
                                setState(() {
                                  _obscureConfirmation =
                                      !_obscureConfirmation;
                                });
                              },
                        icon: Icon(
                          _obscureConfirmation
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return context.strings.text('auth.confirm_password_required');
                      }

                      if (value != _passwordController.text) {
                        return context.strings.text('auth.passwords_mismatch');
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              context.strings.text('auth.save_new_password'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// VT NUM â€” FOND PREMIUM AVEC Ã‰TOILES ANIMÃ‰ES
// ============================================================

class _PremiumStarfield extends StatefulWidget {
  const _PremiumStarfield({required this.child});

  final Widget child;

  @override
  State<_PremiumStarfield> createState() => _PremiumStarfieldState();
}

class _PremiumStarfieldState extends State<_PremiumStarfield>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF050B1D),
                    Color(0xFF10183B),
                    Color(0xFF090E25),
                    Color(0xFF050817),
                  ],
                  stops: [0.0, 0.38, 0.72, 1.0],
                ),
              ),
            ),

            // Halo lumineux supÃ©rieur.
            Positioned(
              top: -140,
              right: -100,
              child: Container(
                width: 340,
                height: 340,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF3D5AFE).withValues(alpha: 0.12),
                ),
              ),
            ),

            // Halo lumineux infÃ©rieur.
            Positioned(
              bottom: -170,
              left: -120,
              child: Container(
                width: 380,
                height: 380,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF9C4DFF).withValues(alpha: 0.10),
                ),
              ),
            ),

            // Ã‰toiles en mouvement.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _StarfieldPainter(_controller.value),
                ),
              ),
            ),

            // Formulaire.
            widget.child,
          ],
        );
      },
    );
  }
}

class _StarfieldPainter extends CustomPainter {
  _StarfieldPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(27);

    for (int i = 0; i < 95; i++) {
      final baseX = random.nextDouble() * size.width;
      final baseY = random.nextDouble() * size.height;
      final radius = 0.5 + random.nextDouble() * 1.5;
      final phase = random.nextDouble() * math.pi * 2;
      final speed = 0.5 + random.nextDouble() * 1.5;

      // Mouvement vertical continu, avec retour en haut.
      final travel = (progress * speed + baseY / size.height) % 1.0;
      final y = travel * size.height;

      // LÃ©ger dÃ©placement horizontal.
      final x = baseX +
          math.sin(progress * math.pi * 2 + phase) * 12;

      // Scintillement.
      final opacity =
          (0.22 + 0.55 * (0.5 + 0.5 * math.sin(
            progress * math.pi * 2 * speed + phase,
          ))).clamp(0.0, 1.0);

      final paint = Paint()
        ..color = Color.fromRGBO(220, 233, 255, opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(x, y),
        radius,
        paint,
      );

      // Quelques Ã©toiles plus brillantes.
      if (i % 15 == 0) {
        final glowPaint = Paint()
          ..color = const Color(0xFF6FA8FF)
              .withValues(alpha: opacity * 0.18)
          ..maskFilter = const MaskFilter.blur(
            BlurStyle.normal,
            7,
          );

        canvas.drawCircle(
          Offset(x, y),
          radius * 3.5,
          glowPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StarfieldPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

// ============================================================
// VT NUM â€” CARTE SIM VIRTUELLE PREMIUM ANIMÃ‰E
// ============================================================

class _PremiumSimCard extends StatefulWidget {
  const _PremiumSimCard();

  @override
  State<_PremiumSimCard> createState() => _PremiumSimCardState();
}

class _PremiumSimCardState extends State<_PremiumSimCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final floatY = math.sin(_controller.value * math.pi) * 8;
        final glow = 0.12 + _controller.value * 0.12;

        return Transform.translate(
          offset: Offset(0, -floatY),
          child: Container(
            width: 224,
            height: 142,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF344B85),
                  Color(0xFF17254E),
                  Color(0xFF10182E),
                ],
              ),
              border: Border.all(
                color: const Color(0xFF9EC5FF).withValues(alpha: 0.65),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4388FF).withValues(alpha: glow),
                  blurRadius: 34,
                  spreadRadius: 2,
                ),
                const BoxShadow(
                  color: Colors.black38,
                  blurRadius: 24,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: Stack(
              children: [
                // Reflet mÃ©tallique.
                Positioned(
                  top: -40,
                  right: -65,
                  child: Transform.rotate(
                    angle: -0.5,
                    child: Container(
                      width: 130,
                      height: 220,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.13),
                            Colors.white.withValues(alpha: 0.01),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 30,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFFFE9A8),
                                Color(0xFFC79B45),
                                Color(0xFFFFF0C6),
                              ],
                            ),
                            border: Border.all(
                              color: const Color(0xFFFFF0C6),
                              width: 0.8,
                            ),
                          ),
                          child: const Icon(
                            Icons.memory_rounded,
                            color: Color(0xFF614B25),
                            size: 23,
                          ),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.wifi_rounded,
                          color: Color(0xFFB9D8FF),
                          size: 23,
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      'VT NUM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.4,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      context.strings.text('auth.brand_descriptor'),
                      style: TextStyle(
                        color: const Color(0xFFB8C9EE)
                            .withValues(alpha: 0.95),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2.0,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.authService});

  final AuthService authService;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _referralCodeController = TextEditingController();

  bool _registering = false;
  bool _submitting = false;
  bool _obscurePassword = true;
  bool _acceptedTerms = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _referralCodeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
  if (_submitting) return;

  // Acceptation obligatoire des CGU avant toute inscription
  if (_registering && !_acceptedTerms) {
    await _showSweetAlert(
      context,
      title: context.strings.text('auth.acceptance_required'),
      message: context.strings.text('auth.terms_required_message'),
      type: _AlertType.info,
      buttonText: context.strings.text('auth.ok'),
    );
    return;
  }

  if (!(_formKey.currentState?.validate() ?? false)) return;

  FocusScope.of(context).unfocus();
  setState(() => _submitting = true);

  try {
      if (_registering) {
        await widget.authService.register(
          email: _emailController.text,
          password: _passwordController.text,
          referralCode: _referralCodeController.text,
        );

        if (!mounted) return;

       await _showSweetAlert(
  context,
  title: context.strings.text('auth.registration_success'),
  message: context.strings.text('auth.registration_message', variables: {'email': _emailController.text.trim()}),
  type: _AlertType.success,
  buttonText: context.strings.text('common.confirm'),
);

if (!mounted) return;

setState(() {
  _registering = false;
  _acceptedTerms = false;
  _passwordController.clear();
  _referralCodeController.clear();
});
      } else {
        await widget.authService.signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
      }
    } on AuthException catch (error) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: _registering ? context.strings.text('auth.registration_failed') : context.strings.text('auth.login_failed'),
        message: _friendlyAuthError(context, error),
        type: _AlertType.error,
        buttonText: context.strings.text('common.retry'),
      );
    } catch (_) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: _registering ? context.strings.text('auth.registration_failed') : context.strings.text('auth.login_error'),
        message: context.strings.text('auth.unexpected_internet_error'),
        type: _AlertType.error,
        buttonText: context.strings.text('common.retry'),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

    @override
  Widget build(BuildContext context) {
    final isRegistering = _registering;

    return Scaffold(
      backgroundColor: const Color(0xFF050817),
      body: _PremiumStarfield(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 24,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),

                      // Logo / marque.
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            color: Color(0xFF83B6FF),
                            size: 24,
                          ),
                          SizedBox(width: 7),
                          Text(
                            'VT NUM',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 32),

                      // SIM virtuelle flottante.
                      const Center(
                        child: _PremiumSimCard(),
                      ),

                      const SizedBox(height: 34),

                      // Titre animÃ©.
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.12),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: Column(
                          key: ValueKey(isRegistering),
                          children: [
                            Text(
                              isRegistering
                                  ? context.strings.text('auth.join_vtnum')
                                  : context.strings.text('auth.digital_world'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                height: 1.2,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              isRegistering
                                  ? context.strings.text('auth.register_subtitle')
                                  : context.strings.text('auth.login_subtitle'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFABB8D6),
                                fontSize: 14,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 30),

                      // Carte contenant le formulaire.
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111A32)
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: const Color(0xFF7EA9FF)
                                .withValues(alpha: 0.18),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 30,
                              offset: const Offset(0, 15),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              isRegistering
                                  ? context.strings.text('auth.create_account')
                                  : context.strings.text('auth.secure_login'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),

                            const SizedBox(height: 7),

                            Text(
                              context.strings.text('auth.privacy_notice'),
                              style: TextStyle(
                                color: Color(0xFF94A6CB),
                                fontSize: 12,
                              ),
                            ),

                            const SizedBox(height: 24),

                            // E-mail.
                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              enabled: !_submitting,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              cursorColor: const Color(0xFF83B6FF),
                              decoration: _premiumInputDecoration(
                                label: context.strings.text('auth.email'),
                                icon: Icons.alternate_email_rounded,
                              ),
                              validator: (value) {
                                final email = value?.trim() ?? '';

                                return RegExp(
                                  r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                                ).hasMatch(email)
                                    ? null
                                    : context.strings.text('auth.invalid_email');
                              },
                            ),

                            const SizedBox(height: 17),

                            // Mot de passe.
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              enabled: !_submitting,
                              autofillHints: isRegistering
                                  ? const [AutofillHints.newPassword]
                                  : const [AutofillHints.password],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              cursorColor: const Color(0xFF83B6FF),
                              decoration: _premiumInputDecoration(
                                label: context.strings.text('auth.password'),
                                icon: Icons.lock_outline_rounded,
                                suffix: IconButton(
                                  onPressed: _submitting
                                      ? null
                                      : () {
                                          setState(() {
                                            _obscurePassword =
                                                !_obscurePassword;
                                          });
                                        },
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: const Color(0xFF9AAED3),
                                    size: 20,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return context.strings.text('auth.password_required');
                                }

                                if (value.length < 8) {
                                  return context.strings.text('auth.password_min_length');
                                }

                                return null;
                              },
                            ),

                            // Optional referral code. Kept separate from existing auth and terms flow.
                            if (isRegistering) ...[
                              const SizedBox(height: 17),
                              TextFormField(
                                controller: _referralCodeController,
                                enabled: !_submitting,
                                textCapitalization: TextCapitalization.characters,
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                                  LengthLimitingTextInputFormatter(10),
                                ],
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                cursorColor: const Color(0xFF83B6FF),
                                decoration: _premiumInputDecoration(
                                  label: context.strings.text('referral.signup_code'),
                                  icon: Icons.card_giftcard_rounded,
                                ).copyWith(
                                  helperText: context.strings.text('referral.signup_optional'),
                                  helperStyle: const TextStyle(color: Color(0xFF94A6CB), fontSize: 11),
                                ),
                              ),
                            ],

                            // CGU : obligatoires pendant l'inscription.
                            if (isRegistering) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.035),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white
                                        .withValues(alpha: 0.08),
                                  ),
                                ),
                                child: CheckboxListTile(
                                  value: _acceptedTerms,
                                  onChanged: _submitting
                                      ? null
                                      : (value) {
                                          setState(() {
                                            _acceptedTerms = value ?? false;
                                          });
                                        },
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  activeColor: const Color(0xFF4788FF),
                                  checkColor: Colors.white,
                                  title: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        context.strings.text('auth.terms_agree_prefix'),
                                        style: TextStyle(
                                          color: Color(0xFFD5DFF5),
                                          fontSize: 12,
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const TermsConditionsPage(),
                                            ),
                                          );
                                        },
                                        child: Text(
                                          context.strings.text('auth.terms_link'),
                                          style: TextStyle(
                                            color: Color(0xFF83B6FF),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            decoration:
                                                TextDecoration.underline,
                                            decorationColor:
                                                Color(0xFF83B6FF),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        context.strings.text('auth.terms_agree_suffix'),
                                        style: TextStyle(
                                          color: Color(0xFFD5DFF5),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],

                            const SizedBox(height: 24),

                            // Bouton principal.
                            SizedBox(
                              height: 57,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: _submitting
                                        ? const [
                                            Color(0xFF5478B9),
                                            Color(0xFF405D9B),
                                          ]
                                        : const [
                                            Color(0xFF69A5FF),
                                            Color(0xFF426BFF),
                                            Color(0xFF7D55F8),
                                          ],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: _submitting
                                      ? const []
                                      : [
                                          BoxShadow(
                                            color: const Color(0xFF426BFF)
                                                .withValues(alpha: 0.27),
                                            blurRadius: 22,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                ),
                                child: ElevatedButton(
                                  onPressed:
                                      _submitting ? null : _submit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    disabledBackgroundColor:
                                        Colors.transparent,
                                    foregroundColor: Colors.white,
                                    disabledForegroundColor: Colors.white70,
                                    shadowColor: Colors.transparent,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: AnimatedSwitcher(
                                    duration:
                                        const Duration(milliseconds: 250),
                                    child: _submitting
                                        ? Row(
                                            key: const ValueKey('loading'),
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              const SizedBox(
                                                width: 21,
                                                height: 21,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2.2,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Text(
                                                isRegistering
                                                    ? context.strings.text('auth.creating_account')
                                                    : context.strings.text('auth.signing_in'),
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ],
                                          )
                                        : Row(
                                            key: const ValueKey('idle'),
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                isRegistering
                                                    ? Icons
                                                        .person_add_alt_1_rounded
                                                    : Icons
                                                        .login_rounded,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                isRegistering
                                                    ? context.strings.text('auth.create_account')
                                                    : context.strings.text('auth.sign_in'),
                                                style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 0.2,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              const Icon(
                                                Icons.arrow_forward_rounded,
                                                size: 19,
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              ),
                            ),

                            if (!isRegistering) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.center,
                                child: TextButton(
                                  onPressed:
                                      _submitting ? null : _resetPassword,
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        const Color(0xFF9FC5FF),
                                  ),
                                  child: Text(
                                    context.strings.text('auth.forgot_password'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 22),

                      // Passage connexion / inscription.
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () {
                                setState(() {
                                  _registering = !_registering;
                                  _acceptedTerms = false;
                                });
                              },
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFB8CBEE),
                        ),
                        child: AnimatedSwitcher(
  duration: const Duration(milliseconds: 250),
  child: Container(
    key: ValueKey(isRegistering),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      vertical: 18,
      horizontal: 16,
    ),
    decoration: BoxDecoration(
      color: const Color(0xFF2563EB).withValues(alpha: 0.08),
      border: Border.all(
        color: const Color(0xFF2563EB),
        width: 1.8,
      ),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      isRegistering
          ? context.strings.text('auth.already_member')
          : context.strings.text('auth.new_member'),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: Color(0xFF2563EB),
      ),
    ),
  ),
),
                      ),

                      const SizedBox(height: 8),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            color: Color(0xFF6E89B8),
                            size: 15,
                          ),
                          SizedBox(width: 7),
                          Text(
                            context.strings.text('auth.brand_tagline'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF788BAF),
                              fontSize: 10,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _premiumInputDecoration({
    required String label,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        color: Color(0xFF93A6CB),
        fontSize: 13,
      ),
      prefixIcon: Icon(
        icon,
        color: const Color(0xFF8EB7FF),
        size: 20,
      ),
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFF080F22),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 19,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(
          color: const Color(0xFF91B6FF).withValues(alpha: 0.16),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(
          color: Color(0xFF70A9FF),
          width: 1.4,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(
          color: Color(0xFFFF6B81),
        ),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(
          color: Color(0xFFFF6B81),
          width: 1.4,
        ),
      ),
    );
  }

  Future<void> _resetPassword() async {
    if (_submitting) return;

    final email = _emailController.text.trim();

    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      await _showSweetAlert(
        context,
        title: context.strings.text('auth.email_required'),
        message: context.strings.text('auth.reset_invalid_email'),
        type: _AlertType.info,
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      await widget.authService.sendPasswordReset(email);

      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('auth.request_sent'),
        message: context.strings.text('auth.reset_request_message'),
        type: _AlertType.success,
      );
    } on AuthException catch (error) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('auth.send_failed'),
        message: _friendlyAuthError(context, error),
        type: _AlertType.error,
        buttonText: context.strings.text('common.retry'),
      );
    } catch (_) {
      if (!mounted) return;

      await _showSweetAlert(
        context,
        title: context.strings.text('common.error'),
        message: context.strings.text('auth.request_error'),
        type: _AlertType.error,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

// context.strings.text('auth.create_account') : context.strings.text('auth.sign_in')
