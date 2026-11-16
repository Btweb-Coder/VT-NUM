
import 'package:flutter/material.dart';

import 'localization/app_localizations.dart';
import '../features/home/home_page.dart';
import '../features/activate/pages/activate_page.dart';
import '../features/active/pages/active_page.dart';
import '../features/orders/pages/orders_page.dart';
import '../features/wallet/pages/wallet_page.dart';
import '../features/profile/pages/profile_page.dart';
import '../features/referrals/pages/referral_page.dart';
import '../features/rentals/pages/rentals_page.dart';
import '../features/support/pages/support_chat_page.dart';
import '../core/services/catalog_bootstrap_service.dart';

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  int currentIndex = 0;
  bool _moreOpen = false;
  bool _supportChatOpen = false;
  bool _supportChatInitialized = false;

  late final List<Widget?> pages;

  @override
  void initState() {
    super.initState();

    CatalogBootstrapService.instance.start();

    pages = [
      HomePage(
        onOpenActivation: () => changePage(1),
        onOpenActive: () => changePage(2),
        onOpenWalletTopUp: _openWalletTopUp,
      ),
      null,
      const ActivePage(),
      const OrdersPage(),
    ];
  }

  void changePage(int index) {
    if (index == currentIndex) return;

    setState(() {
      currentIndex = index;

      if (index == 1) {
        pages[1] = const ActivatePage(isVisible: true);
      } else if (pages[1] != null) {
        pages[1] = const ActivatePage(isVisible: false);
      }
    });
  }

  void _openSupportChat() {
    if (_supportChatOpen) return;

    setState(() {
      _supportChatInitialized = true;
      _supportChatOpen = true;
    });
  }

  void _closeSupportChat() {
    if (!_supportChatOpen) return;
    setState(() => _supportChatOpen = false);
  }

  Future<void> openMore() async {
    if (_moreOpen) return;
    setState(() => _moreOpen = true);

    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) {
          return _MoreSheet(
            onWallet: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WalletPage()),
              );
            },
            onRentals: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RentalsPage()),
              );
            },
            onProfile: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfilePage()),
              );
            },
            onReferrals: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReferralPage()),
              );
            },
          );
        },
      );
    } finally {
      if (mounted) setState(() => _moreOpen = false);
    }
  }

  Future<void> _openWalletTopUp() async {
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const WalletPage(openTopUpOnStart: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: currentIndex,
            children: [
              pages[0] ?? const SizedBox.shrink(),
              pages[1] ?? const SizedBox.shrink(),
              pages[2] ?? const SizedBox.shrink(),
              pages[3] ?? const SizedBox.shrink(),
            ],
          ),

          // Keep the WebView mounted after its first initialization.
          if (_supportChatInitialized)
            Positioned.fill(
              child: Offstage(
                offstage: !_supportChatOpen,
                child: SupportChatPage(
                  isVisible: _supportChatOpen,
                  onClose: _closeSupportChat,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton:
          currentIndex < pages.length &&
              !_moreOpen &&
              !_supportChatOpen &&
              ModalRoute.of(context)?.isCurrent == true &&
              MediaQuery.viewInsetsOf(context).bottom == 0
          ? _SupportPromptButton(onPressed: _openSupportChat)
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          if (index == 4) {
            openMore();
            return;
          }

          changePage(index);
        },
        backgroundColor: const Color(0xFF0C101B),
        indicatorColor: const Color(0xFF1B2C5B),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: context.strings.text('navigation.home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.bolt_outlined),
            selectedIcon: const Icon(Icons.bolt),
            label: context.strings.text('navigation.activate'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.access_time_outlined),
            selectedIcon: const Icon(Icons.access_time_filled),
            label: context.strings.text('navigation.active'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            label: context.strings.text('navigation.orders'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.more_horiz),
            selectedIcon: const Icon(Icons.more_horiz),
            label: context.strings.text('navigation.more'),
          ),
        ],
      ),
    );
  }
}

class _SupportPromptButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _SupportPromptButton({required this.onPressed});

  @override
  State<_SupportPromptButton> createState() => _SupportPromptButtonState();
}

class _SupportPromptButtonState extends State<_SupportPromptButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween<double>(
    begin: 0.97,
    end: 1.03,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Informational label only: deliberately has no tap handler.
        ScaleTransition(
          scale: _pulse,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 15,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF182448),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xFF0066FF).withValues(alpha: 0.55),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0066FF).withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              context.strings.text('support.prompt_title'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FloatingActionButton(
          heroTag: 'online-sim-support-chat',
          backgroundColor: const Color(0xFF0066FF),
          foregroundColor: Colors.white,
          onPressed: widget.onPressed,
          child: const Icon(Icons.chat_bubble_outline_rounded),
        ),
      ],
    );
  }
}

class _MoreSheet extends StatelessWidget {
  final VoidCallback onWallet;
  final VoidCallback onRentals;
  final VoidCallback onProfile;
  final VoidCallback onReferrals;

  const _MoreSheet({
    required this.onWallet,
    required this.onRentals,
    required this.onProfile,
    required this.onReferrals,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
      decoration: const BoxDecoration(
        color: Color(0xFF101522),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.strings.text('navigation.more'),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _item(
            icon: Icons.event_repeat_outlined,
            title: context.strings.text('navigation.rentals'),
            onTap: onRentals,
          ),
          _item(
            icon: Icons.account_balance_wallet_outlined,
            title: context.strings.text('wallet.title'),
            onTap: onWallet,
          ),
          _item(
            icon: Icons.card_giftcard_outlined,
            title: context.strings.text('referral.title'),
            onTap: onReferrals,
          ),
          _item(
            icon: Icons.person_outline,
            title: context.strings.text('navigation.profile'),
            onTap: onProfile,
          ),
        ],
      ),
    );
  }

  Widget _item({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon),
      ),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
    );
  }
}
