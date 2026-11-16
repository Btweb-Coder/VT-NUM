
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/localization/app_localizations.dart';
import '../../core/services/app_update_service.dart';
import '../auth/pages/auth_gate.dart';
import '../onboarding/onboarding_gate.dart';

class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key});

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  late final Future<String> _installedVersion = _readInstalledVersion();

  Future<String> _readInstalledVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _installedVersion,
        builder: (context, versionSnapshot) {
          if (versionSnapshot.connectionState != ConnectionState.done) {
            return const _LoadingScreen();
          }

          if (versionSnapshot.hasError || !versionSnapshot.hasData) {
            return OnboardingGate(child: AuthGate());
          }

          return StreamBuilder<AppUpdateInfo>(
            stream: AppUpdateService().watch(),
            builder: (context, updateSnapshot) {
              final update = updateSnapshot.data;

              if (update != null &&
                  update.requiresUpdate(versionSnapshot.data!)) {
                return _RequiredUpdateScreen(update: update);
              }

              return OnboardingGate(child: AuthGate());
            },
          );
        },
      );
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class _RequiredUpdateScreen extends StatefulWidget {
  const _RequiredUpdateScreen({required this.update});

  final AppUpdateInfo update;

  @override
  State<_RequiredUpdateScreen> createState() =>
      _RequiredUpdateScreenState();
}

class _RequiredUpdateScreenState extends State<_RequiredUpdateScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entryController;
  late final AnimationController _pulseController;

  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _iconScaleAnimation;
  late final Animation<double> _iconRotationAnimation;
  late final Animation<double> _pulseAnimation;

  bool _openingLink = false;

  @override
  void initState() {
    super.initState();

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _entryController,
        curve: Curves.easeOutCubic,
      ),
    );

    _iconScaleAnimation = Tween<double>(
      begin: 0.65,
      end: 1,
    ).animate(
      CurvedAnimation(
        parent: _entryController,
        curve: const Interval(0.0, 0.65, curve: Curves.elasticOut),
      ),
    );

    _iconRotationAnimation = Tween<double>(
      begin: -0.12,
      end: 0,
    ).animate(
      CurvedAnimation(
        parent: _entryController,
        curve: Curves.easeOutBack,
      ),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 0.96,
      end: 1.045,
    ).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );

    _entryController.forward();
  }

  @override
  void dispose() {
    _entryController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_openingLink) return;

    setState(() => _openingLink = true);

    try {
      final uri = Uri.parse(widget.update.downloadUrl);

      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.strings.text('app_update.open_error'),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.strings.text('app_update.open_error'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _openingLink = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Animated update icon
                      ScaleTransition(
                        scale: _iconScaleAnimation,
                        child: RotationTransition(
                          turns: _iconRotationAnimation,
                          child: AnimatedBuilder(
                            animation: _pulseAnimation,
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _pulseAnimation.value,
                                child: child,
                              );
                            },
                            child: Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                color: primaryColor.withOpacity(0.10),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: primaryColor.withOpacity(0.16),
                                    blurRadius: 28,
                                    spreadRadius: 5,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.system_update_rounded,
                                size: 62,
                                color: primaryColor,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 34),

                      Text(
                        context.strings.text(
                          'app_update.required_title',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                        ),
                      ),

                      const SizedBox(height: 14),

                      Text(
                        context.strings.text(
                          'app_update.required_message',
                          variables: {
                            'version': widget.update.requiredVersion,
                          },
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.6,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),

                      const SizedBox(height: 42),

                      // Prominent animated update button
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: 1 + ((_pulseAnimation.value - 1) * 0.35),
                            child: child,
                          );
                        },
                        child: SizedBox(
                          width: double.infinity,
                          height: 68,
                          child: ElevatedButton.icon(
                            onPressed: _openingLink ? null : _download,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  primaryColor.withOpacity(0.65),
                              elevation: 9,
                              shadowColor:
                                  primaryColor.withOpacity(0.45),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(19),
                              ),
                            ),
                            icon: _openingLink
                                ? const SizedBox(
                                    width: 25,
                                    height: 25,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.system_update_alt_rounded,
                                    size: 30,
                                  ),
                            label: Text(
                              context.strings
                                  .text('app_update.update_button')
                                  .toUpperCase(),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 22),

                      Text(
                        'VT NUM',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 1.8,
                        ),
                      ),
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
}
