import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'onboarding_page.dart';

class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  bool? _completed;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final completed =
          preferences.getBool('online_sim_onboarding_completed') ?? false;

      if (mounted) setState(() => _completed = completed);
    } catch (_) {
      // En cas d'erreur de stockage, ne pas bloquer l'accès à l'application.
      if (mounted) setState(() => _completed = true);
    }
  }

  Future<void> _finishOnboarding() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('online_sim_onboarding_completed', true);
      await preferences.setBool('online_sim_first_time_guide_pending', true);
      await preferences.setBool('online_sim_first_time_guide_enabled', true);
    } catch (_) {
      // L'accès à l'application reste possible même si la sauvegarde échoue.
    }

    if (mounted) setState(() => _completed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_completed == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF080B18),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF8B7CFF)),
        ),
      );
    }

    if (_completed!) return widget.child;

    return OnboardingPage(onFinished: _finishOnboarding);
  }
}
