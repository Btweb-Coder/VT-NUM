import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepareFirstTimeGuide();
  }

  Future<void> _prepareFirstTimeGuide() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final completed =
          preferences.getBool('online_sim_onboarding_completed') ?? false;

      if (!completed) {
        // The interactive guide replaces the previous generic first-run slides.
        await preferences.setBool('online_sim_onboarding_completed', true);
        await preferences.setBool(
          'online_sim_first_time_guide_pending',
          true,
        );
      }
    } catch (_) {
      // Storage errors must never block access to the app.
    }

    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF080B18),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF8B7CFF)),
        ),
      );
    }

    return widget.child;
  }
}
