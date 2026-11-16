import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../app/localization/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/pages/terms_conditions_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _starsController;

  bool _signingOut = false;

  String get _userEmail {
    return Supabase.instance.client.auth.currentUser?.email ??
        context.strings.text('profile.email_unavailable');
  }

  @override
  void initState() {
    super.initState();

    _starsController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 28),
    )..repeat();
  }

  @override
  void dispose() {
    _starsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050816),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          context.strings.text('profile.title'),
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
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
          ),

          Positioned(
            top: 20,
            right: -110,
            child: _glow(300, const Color(0xFF5145FF)),
          ),

          Positioned(
            bottom: 100,
            left: -150,
            child: _glow(300, const Color(0xFF0878F9)),
          ),

          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _starsController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _ProfileStarsPainter(
                      progress: _starsController.value,
                    ),
                  );
                },
              ),
            ),
          ),

          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 35),
              children: [
                _buildIdentityCard(),

                const SizedBox(height: 30),

                _buildSectionTitle(context.strings.text('profile.account_heading')),

                const SizedBox(height: 13),

                _buildMenuItem(
                  icon: Icons.person_outline_rounded,
                  title: context.strings.text('profile.personal_info'),
                  subtitle: context.strings.text('profile.personal_subtitle'),
                  iconColor: const Color(0xFF8B9BFF),
                  onTap: _showAccountInfo,
                ),

                _buildMenuItem(
                  icon: Icons.verified_user_outlined,
                  title: context.strings.text('profile.terms_privacy'),
                  subtitle: context.strings.text('profile.terms_subtitle'),
                  iconColor: const Color(0xFFC4B5FD),
                  onTap: _openTerms,
                ),

                const SizedBox(height: 20),

                _buildSectionTitle('SESSION'),

                const SizedBox(height: 13),

                _buildLogoutButton(),

                const SizedBox(height: 28),

                _buildFooter(),
              ],
            ),
          ),
        ],
      ),
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

  Widget _buildIdentityCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 25),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1B2A50),
            Color(0xFF171A3B),
            Color(0xFF251A43),
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5145FF).withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF4776FF),
                  Color(0xFF8B5CF6),
                ],
              ),
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6366F1)
                      .withValues(alpha: 0.30),
                  blurRadius: 25,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(
                  Icons.sim_card_rounded,
                  size: 66,
                  color: Colors.white,
                ),
                Positioned(
                  right: 23,
                  bottom: 29,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC4B5FD),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 21),

          Text(
            _userEmail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFCDD6FF),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 9),

          Text(
            context.strings.text('profile.user_account'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 23,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),

          const SizedBox(height: 13),

          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF10B981).withValues(alpha: 0.25),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.verified_user_rounded,
                  color: Color(0xFF6EE7B7),
                  size: 15,
                ),
                SizedBox(width: 7),
                Text(
                  'VT NUM PREMIUM',
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
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF8998B7),
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 15,
              vertical: 17,
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor,
                    size: 23,
                  ),
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
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFF8998B7),
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF8998B7),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogoutButton() {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: ElevatedButton(
        onPressed: _signingOut ? null : _signOut,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFEF4444).withValues(alpha: 0.12),
          disabledBackgroundColor:
              const Color(0xFFEF4444).withValues(alpha: 0.08),
          foregroundColor: const Color(0xFFFF8585),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(19),
            side: BorderSide(
              color: const Color(0xFFEF4444).withValues(alpha: 0.30),
            ),
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _signingOut
              ? Row(
                  key: ValueKey('signing-out'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Color(0xFFFF8585),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      context.strings.text('profile.signing_out'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                )
              : Row(
                  key: ValueKey('logout'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout_rounded, size: 20),
                    SizedBox(width: 10),
                    Text(
                      context.strings.text('profile.sign_out'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.shield_outlined,
          size: 16,
          color: Colors.white.withValues(alpha: 0.40),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            context.strings.text('profile.footer'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  void _openTerms() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TermsConditionsPage(),
      ),
    );
  }

  void _showAccountInfo() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF111A32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Text(
            context.strings.text('profile.personal_info'),
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('profile.email'),
                style: TextStyle(
                  color: Color(0xFF8998B7),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 7),
              SelectableText(
                _userEmail,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                context.strings.text('common.close'),
                style: TextStyle(
                  color: Color(0xFF9CB4FF),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _signOut() async {
    if (_signingOut) return;

    setState(() {
      _signingOut = true;
    });

    try {
      await Supabase.instance.client.auth.signOut();

      if (!mounted) return;

      // L'AuthGate doit écouter les changements d'authentification
      // et afficher automatiquement l'écran de connexion.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.strings.text('profile.signout_success')),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.strings.text('profile.signout_error'),
          ),
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _signingOut = false;
        });
      }
    }
  }
}

class _ProfileStarsPainter extends CustomPainter {
  final double progress;

  _ProfileStarsPainter({
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
  bool shouldRepaint(covariant _ProfileStarsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
