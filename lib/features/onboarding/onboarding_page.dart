import 'package:flutter/material.dart';
import '../../app/localization/app_localizations.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onFinished});

  final Future<void> Function() onFinished;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  final PageController _controller = PageController();

  late final AnimationController _floatController;
  late final Animation<double> _floatAnimation;

  int _index = 0;
  bool _finishing = false;

  static const _background = Color(0xFF080B18);
  static const _purple = Color(0xFF8B7CFF);
  static const _blue = Color(0xFF4D8DFF);

  static const _slides = <_SlideData>[
    _SlideData(
      eyebrow: 'onboarding.slide1.eyebrow',
      title: 'onboarding.slide1.title',
      description: 'onboarding.slide1.description',
      icon: Icons.trending_up_rounded,
      color: Color(0xFF8B7CFF),
      tag: 'onboarding.slide1.tag',
    ),
    _SlideData(
      eyebrow: 'onboarding.slide2.eyebrow',
      title: 'onboarding.slide2.title',
      description: 'onboarding.slide2.description',
      icon: Icons.shield_rounded,
      color: Color(0xFF4D8DFF),
      tag: 'onboarding.slide2.tag',
    ),
    _SlideData(
      eyebrow: 'onboarding.slide3.eyebrow',
      title: 'onboarding.slide3.title',
      description: 'onboarding.slide3.description',
      icon: Icons.verified_rounded,
      color: Color(0xFF35D6B0),
      tag: 'onboarding.slide3.tag',
    ),
    _SlideData(
      eyebrow: 'onboarding.slide4.eyebrow',
      title: 'onboarding.slide4.title',
      description: 'onboarding.slide4.description',
      icon: Icons.sim_card_rounded,
      color: Color(0xFFFFB86B),
      tag: 'onboarding.slide4.tag',
    ),
  ];

  @override
  void initState() {
    super.initState();

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _floatAnimation = Tween<double>(begin: -9, end: 9).animate(
      CurvedAnimation(
        parent: _floatController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _floatController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_finishing) return;

    setState(() => _finishing = true);
    await widget.onFinished();
  }

  void _next() {
    if (_index < _slides.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _previous() {
  if (_index > 0) {
    _controller.previousPage(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubic,
    );
  }
}

// width: double.infinity,

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_index];

    return Scaffold(
      backgroundColor: _background,
      body: Stack(
        children: [
          Positioned(
            top: -120,
            right: -100,
            child: _Glow(color: slide.color, size: 300),
          ),
          Positioned(
            bottom: 70,
            left: -170,
            child: _Glow(color: _blue, size: 280),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(13),
                          gradient: const LinearGradient(
                            colors: [_purple, _blue],
                          ),
                        ),
                        child: const Icon(
                          Icons.sim_card_rounded,
                          color: Colors.white,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Text(
                        'VT NUM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _finishing ? null : _finish,
                        child: Text(
                          context.strings.text('onboarding.skip'),
                          style: TextStyle(
                            color: Color(0xFFB9BDD0),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _slides.length,
                    onPageChanged: (value) => setState(() => _index = value),
                    itemBuilder: (context, index) {
                      final item = _slides[index];

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight - 24,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 8),
                                  AnimatedBuilder(
                                    animation: _floatAnimation,
                                    builder: (context, child) {
                                      return Transform.translate(
                                        offset: Offset(
                                          0,
                                          index == _index
                                              ? _floatAnimation.value
                                              : 0,
                                        ),
                                        child: child,
                                      );
                                    },
                                    child: _Illustration(
                                      slide: item,
                                      number: index + 1,
                                    ),
                                  ),
                                  const SizedBox(height: 35),
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 400),
                                    transitionBuilder: (child, animation) {
                                      final curved = CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      );
                                      return FadeTransition(
                                        opacity: animation,
                                        child: SlideTransition(
                                          position: Tween<Offset>(
                                            begin: const Offset(0, 0.12),
                                            end: Offset.zero,
                                          ).animate(curved),
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: Column(
                                      key: ValueKey(index),
                                      children: [
                                        Text(
                                          context.strings.text(item.eyebrow),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: item.color,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2.3,
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          context.strings.text(item.title),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 32,
                                            height: 1.15,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -0.8,
                                          ),
                                        ),
                                        const SizedBox(height: 17),
                                        Text(
                                          context.strings.text(item.description),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Color(0xFFB5BBD0),
                                            fontSize: 15,
                                            height: 1.75,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 25),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(_slides.length, (index) {
                          final active = index == _index;

                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: active ? 30 : 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: active
                                  ? slide.color
                                  : const Color(0xFF34394D),
                              borderRadius: BorderRadius.circular(20),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 25),
                      Row(
  children: [
    if (_index > 0) ...[
      Expanded(
        flex: 2,
        child: SizedBox(
          height: 58,
          child: OutlinedButton.icon(
            onPressed: _finishing ? null : _previous,
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(context.strings.text('onboarding.previous')),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(
                color: Color(0xFF34394D),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(19),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 12),
    ],
    Expanded(
      flex: 3,
      child: SizedBox(
        height: 58,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [slide.color, _blue],
            ),
            borderRadius: BorderRadius.circular(19),
            boxShadow: [
              BoxShadow(
                color: slide.color.withValues(alpha: 0.24),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: _finishing ? null : _next,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(19),
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _finishing
                  ? const SizedBox(
                      key: ValueKey('loading'),
                      width: 23,
                      height: 23,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      key: ValueKey(_index),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _index == _slides.length - 1
                                ? context.strings.text('onboarding.start')
                                : context.strings.text('onboarding.next'),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          size: 20,
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    ),
  ],
),
                      const SizedBox(height: 13),
                      Text(
                        '${_index + 1} / ${_slides.length}',
                        style: const TextStyle(
                          color: Color(0xFF777F98),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideData {
  const _SlideData({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.tag,
  });

  final String eyebrow;
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final String tag;
}

class _Illustration extends StatelessWidget {
  const _Illustration({required this.slide, required this.number});

  final _SlideData slide;
  final int number;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 255,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 224,
            height: 224,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: slide.color.withValues(alpha: 0.14),
                width: 1.2,
              ),
            ),
          ),
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: slide.color.withValues(alpha: 0.06),
              border: Border.all(
                color: slide.color.withValues(alpha: 0.20),
              ),
            ),
          ),
          Container(
            width: 140,
            height: 166,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              color: const Color(0xFF151A2D),
              border: Border.all(
                color: slide.color.withValues(alpha: 0.7),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: slide.color.withValues(alpha: 0.18),
                  blurRadius: 35,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: slide.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    slide.icon,
                    color: slide.color,
                    size: 29,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: 72,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 9),
                Container(
                  width: 48,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: slide.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    color: slide.color,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 27,
            right: 15,
            child: _FloatingBadge(
              color: slide.color,
              icon: slide.icon,
            ),
          ),
          Positioned(
            bottom: 25,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 13,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1B2035),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: slide.color.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      color: slide.color, size: 15),
                  const SizedBox(width: 7),
                  Text(
                    context.strings.text(slide.tag),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 25,
            right: 15,
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: slide.color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: slide.color.withValues(alpha: 0.35),
                    blurRadius: 15,
                  ),
                ],
              ),
              child: Text(
                '0$number',
                style: const TextStyle(
                  color: Color(0xFF080B18),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingBadge extends StatelessWidget {
  const _FloatingBadge({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 49,
      height: 49,
      decoration: BoxDecoration(
        color: const Color(0xFF1B2035),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.18),
            blurRadius: 20,
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 25),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: 0.16),
              color.withValues(alpha: 0.04),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}
// _next()