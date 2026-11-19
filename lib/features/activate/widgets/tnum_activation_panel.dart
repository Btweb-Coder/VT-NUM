import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:uuid/uuid.dart';

import '../../../app/localization/app_localizations.dart';
import '../../../app/theme/colors.dart';
import '../../../core/services/catalog_bootstrap_service.dart';
import '../data/tnum_activation.dart';
import '../data/tnum_repository.dart';
import '../../orders/pages/tnum_operation_details_page.dart';
import '../../wallet/pages/wallet_page.dart';
import 'tnum_feedback.dart';
import '../../onboarding/first_time_app_guide.dart';

class TnumActivationPanel extends StatefulWidget {
  const TnumActivationPanel({
    super.key,
    this.repository,
    this.catalogLoader,
    this.countryRefresher,
  });

  final TnumRepository? repository;
  final Future<CatalogLoad<TnumCatalogSnapshot>> Function()? catalogLoader;
  final Future<CatalogLoad<TnumCatalogSnapshot>> Function(int code)?
  countryRefresher;

  @override
  State<TnumActivationPanel> createState() => _TnumActivationPanelState();
}

class _TnumActivationPanelState extends State<TnumActivationPanel> {
  late final _repository = widget.repository ?? TnumRepository();
  final _search = TextEditingController();
  final ScrollController _guideScrollController = ScrollController();
  Timer? _pollTimer;
  List<Map<String, dynamic>> _countries = [];
  List<TnumCatalogItem> _catalog = [];
  List<Map<String, dynamic>> _activations = [];
  List<Map<String, dynamic>> _history = [];
  int? _countryCode;
  bool _loading = true;
  bool _busy = false;
  bool _offline = false;
  bool _showHistory = false;
  bool _historyLoading = false;
  bool _openingDetails = false;
  bool _ordering = false;
  bool _feedbackDialogOpen = false;
  String? _error;
  TnumFeedbackMessage? _historyError;
  String? _selectedServiceSlug;

  @override
  void initState() {
    super.initState();
    FirstTimeAppGuide.registerReveal('activate', () {
      if (_guideScrollController.hasClients) {
        _guideScrollController.animateTo(
          _guideScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
    _loadBootstrappedCatalog();
    unawaited(_refresh());
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    FirstTimeAppGuide.unregisterReveal('activate');
    _guideScrollController.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadBootstrappedCatalog() async {
    final loaded =
        await (widget.catalogLoader?.call() ??
            CatalogBootstrapService.instance.tnumCatalog);
    if (!mounted) return;
    setState(() {
      _countries = loaded.data.countries;
      _countryCode =
          _countryCode ??
          (_countries.isEmpty
              ? null
              : int.tryParse('${_countries.first['code']}'));
      _catalog = loaded.data.catalog.map(TnumCatalogItem.fromMap).toList();
      _selectedServiceSlug ??= _visibleItems.firstOrNull?.serviceSlug;
      _error = loaded.error == null
          ? null
          : context.strings.text('tnum.catalog_error');
      _loading = false;
    });
  }

  Future<void> _selectCountry(int code) async {
    setState(() {
      _countryCode = code;
      _loading = true;
      _error = null;
    });
    final loaded =
        await (widget.countryRefresher?.call(code) ??
            CatalogBootstrapService.instance.refreshTnumCountry(code));
    if (!mounted) return;
    setState(() {
      _countries = loaded.data.countries;
      _catalog = loaded.data.catalog.map(TnumCatalogItem.fromMap).toList();
      if (!_visibleItems.any(
        (item) => item.serviceSlug == _selectedServiceSlug,
      )) {
        _selectedServiceSlug = _visibleItems.firstOrNull?.serviceSlug;
      }
      _error = loaded.error == null
          ? null
          : context.strings.text('tnum.catalog_error');
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await _repository.poll();
      if (!mounted) return;
      setState(() {
        _activations = (result['activations'] as List? ?? [])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _offline = false;
      });
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    } finally {
      _busy = false;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && !_openingDetails) unawaited(_refresh());
    });
  }

  Future<void> _openDetails(
    String activationId, {
    bool purchaseConfirmed = false,
  }) async {
    if (_openingDetails || activationId.trim().isEmpty) return;
    _openingDetails = true;
    _pollTimer?.cancel();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => TnumOperationDetailsPage(
            activationId: activationId,
            repository: _repository,
            purchaseConfirmed: purchaseConfirmed,
          ),
        ),
      );
    } finally {
      if (mounted) {
        _openingDetails = false;
        await _refresh();
        if (mounted) _startPolling();
      }
    }
  }

  Future<void> _loadHistory() async {
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final rows = await _repository.activations(history: true);
      if (mounted) setState(() => _history = rows);
    } catch (error) {
      if (mounted) {
        setState(() => _historyError = TnumFeedbackMessage.fromError(error));
      }
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _order(TnumCatalogItem item) async {
    if (_ordering) return;

    setState(() => _ordering = true);

    var key = const Uuid().v4();
    TnumQuote? currentQuote;

    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final quote = await _repository.quote(
          item.serviceSlug,
          item.countryCode,
        );
        currentQuote = quote;

        if (!mounted) return;

        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.help_outline_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(context.strings.text('tnum.confirm_title')),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (attempt > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      context.strings.text('tnum.price_changed'),
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                Text(
                  context.strings.text(
                    'tnum.confirm_price',
                    variables: {
                      'service': item.serviceName,
                      'country': item.countryName,
                      'price': _money(quote.customerPriceCents),
                    },
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.strings.text('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(context.strings.text('tnum.confirm')),
              ),
            ],
          ),
        );

        if (confirmed != true) return;

        try {
          final result = await _repository.requestActivation(
            service: item.serviceSlug,
            country: item.countryCode,
            idempotencyKey: key,
            quoteId: quote.id,
          );

          if (!mounted) return;

          final activation = result['activation'];
          final activationId = activation is Map
              ? '${activation['id'] ?? ''}'.trim()
              : '';

          if (activationId.isNotEmpty) {
            await _openDetails(
              activationId,
              purchaseConfirmed: '${activation['status'] ?? ''}' == 'active',
            );
          } else {
            await _refresh();

            if (!mounted) return;

            await _showFeedback(
              const TnumFeedbackMessage(
                titleKey: 'tnum.feedback.verification_title',
                messageKey: 'tnum.feedback.uncertain_body',
                kind: TnumFeedbackKind.info,
              ),
            );
          }

          return;
        } on TnumRepositoryException catch (error) {
          if (error.code == 'PRICE_CHANGED' || error.code == 'QUOTE_EXPIRED') {
            key = const Uuid().v4();
            if (attempt < 2) continue;
          }
          rethrow;
        }
      }
    } catch (error) {
      if (!mounted) return;
      await _showOrderFailure(error, currentQuote?.customerPriceCents);
    } finally {
      if (mounted) {
        setState(() => _ordering = false);
      } else {
        _ordering = false;
      }
    }
  }

  Future<void> _showFeedback(TnumFeedbackMessage message) async {
    if (!mounted || _feedbackDialogOpen) return;
    _feedbackDialogOpen = true;
    try {
      await message.show(context);
    } finally {
      _feedbackDialogOpen = false;
    }
  }

  Future<void> _showOrderFailure(Object error, int? requiredCents) async {
    if (!mounted) return;
    final strings = context.strings;
    final message = TnumFeedbackMessage.fromError(error);
    if (message.titleKey != 'tnum.feedback.insufficient_title') {
      await _showFeedback(message);
      return;
    }
    var amountDetails = '';
    if (requiredCents != null) {
      try {
        final wallet = await _repository.wallet();
        final availableCents = (wallet['available_cents'] as num?)?.toInt();
        if (availableCents != null) {
          final missing = (requiredCents - availableCents).clamp(
            0,
            requiredCents,
          );
          amountDetails =
              '\n\n${strings.text('tnum.feedback.amounts', variables: {'available': _money(availableCents), 'required': _money(requiredCents), 'missing': _money(missing)})}';
        }
      } catch (_) {
        // The insufficient-balance explanation remains useful without balances.
      }
    }
    if (!mounted || _feedbackDialogOpen) return;
    _feedbackDialogOpen = true;
    try {
      await TnumFeedbackDialog.show(
        context,
        title: context.strings.text(message.titleKey),
        message: '${context.strings.text(message.messageKey)}$amountDetails',
        kind: message.kind,
        actionLabel: context.strings.text('tnum.feedback.top_up'),
        onAction: () => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => const WalletPage(
      openTopUpOnStart: true,
    ),
  ),
),
      );
    } finally {
      _feedbackDialogOpen = false;
    }
  }

  Future<void> _action(String id, bool complete) async {
    try {
      if (complete) {
        await _repository.complete(id);
      } else {
        await _repository.nextSms(id);
      }
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      await _showFeedback(TnumFeedbackMessage.fromError(error));
    }
  }

  String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  List<TnumCatalogItem> get _visibleItems {
    final query = _search.text.trim().toLowerCase();
    return _catalog
        .where(
          (item) =>
              (_countryCode == null || item.countryCode == _countryCode) &&
              (query.isEmpty ||
                  '${item.serviceName} ${item.countryName} ${item.serviceSlug}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
  }

  List<TnumCatalogItem> get _visibleServices {
    final bySlug = <String, TnumCatalogItem>{};
    for (final item in _visibleItems) {
      bySlug.putIfAbsent(item.serviceSlug, () => item);
    }
    return bySlug.values.toList();
  }

  TnumCatalogItem? get _selectedItem {
    for (final item in _visibleItems) {
      if (item.serviceSlug == _selectedServiceSlug) return item;
    }
    return _visibleItems.firstOrNull;
  }

  @override
  Widget build(BuildContext context) => _showHistory
      ? _buildOperations(_history, history: true)
      : ListView(
          key: const ValueKey('tnum-catalog'),
          controller: _guideScrollController,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 35),
          children: [
            _buildHeader(),
            const SizedBox(height: 28),
            FirstTimeAppGuide.anchor(
              'activate',
              'T-NUM: COUNTRY AND SERVICE',
              Column(
                children: [
                  _buildSelectorSection(
                    label: context.strings.text('tnum.service'),
                    value:
                        _selectedItem?.serviceName ??
                        context.strings.text('tnum.search'),
                    leading: Icon(
                      _serviceIcon(_selectedItem?.serviceName ?? ''),
                      color: const Color(0xFF93B4FF),
                    ),
                    onTap: _showServiceSheet,
                  ),
                  const SizedBox(height: 22),
                  _buildSelectorSection(
                    label: context.strings.text('tnum.country'),
                    value: _selectedCountryName,
                    leading: _countryFlag(_selectedCountry),
                    onTap: _showCountrySheet,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            FirstTimeAppGuide.anchor(
              'activate',
              'T-NUM: PRICE AND PURCHASE',
              Column(
                children: [
                  _buildPriceCard(),
                  const SizedBox(height: 22),
                  _buildPurchaseButton(),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (_offline)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  context.strings.text('tnum.offline'),
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (!_loading && _selectedItem == null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.strings.text('tnum.empty'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFA5B4D0)),
                ),
              ),
            const SizedBox(height: 18),
            FirstTimeAppGuide.anchor(
              'activate',
              'NUMBER AND SMS',
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings.text('tnum.active_title'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: Color(0xFF93B4FF),
                    ),
                  ),
                ],
              ),
            ),
            if (_activations.isEmpty)
              Text(
                context.strings.text('tnum.no_active'),
                style: const TextStyle(color: Color(0xFFA5B4D0)),
              ),
            ..._activations.map((row) => _activationCard(row, history: false)),
          ],
        );

  String get _selectedCountryName {
    for (final country in _countries) {
      if (int.tryParse('${country['code']}') == _countryCode) {
        return '${country['name']}';
      }
    }
    return context.strings.text('tnum.country');
  }

  Map<String, dynamic>? get _selectedCountry {
    for (final country in _countries) {
      if (int.tryParse('${country['code']}') == _countryCode) return country;
    }
    return null;
  }

  Widget _buildHeader() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Top row: icon + T-NUM history button
      Row(
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

          const Spacer(),

          _historyButton(),
        ],
      ),

      const SizedBox(height: 22),

      // Title — same as VT-NUM
      Text(
        context.strings.text('activation.title'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 31,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.8,
        ),
      ),

      const SizedBox(height: 9),

      // Description — same as VT-NUM
      Text(
        context.strings.text('activation.subtitle'),
        style: const TextStyle(
          color: Color(0xFFA5B4D0),
          fontSize: 14,
          height: 1.6,
        ),
      ),

      const SizedBox(height: 17),

      // Security badge — same as VT-NUM
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
            const Icon(
              Icons.verified_user_outlined,
              size: 15,
              color: Color(0xFF34D399),
            ),
            const SizedBox(width: 7),
            Text(
              context.strings.text('activation.secure'),
              style: const TextStyle(
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

  Widget _historyButton() => Material(
    color: const Color(0xFF111A32),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        setState(() => _showHistory = true);
        await _loadHistory();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF8294BD).withValues(alpha: .18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.history_rounded,
              color: Color(0xFF93B4FF),
              size: 17,
            ),
            const SizedBox(width: 5),
            Text(
              context.strings.text('tnum.history'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildSelectorSection({
    required String label,
    required String value,
    required Widget leading,
    required VoidCallback onTap,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
          letterSpacing: .2,
        ),
      ),
      const SizedBox(height: 10),
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF111A32).withValues(alpha: .92),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF8294BD).withValues(alpha: .18),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .12),
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
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF4776FF).withValues(alpha: .20),
                        const Color(0xFF8B5CF6).withValues(alpha: .12),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Center(child: leading),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Tap to change selection',
                        style: TextStyle(
                          color: Color(0xFFA5B4D0),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Color(0xFF93B4FF),
                  size: 25,
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildPriceCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF182448), Color(0xFF151A35), Color(0xFF21183D)],
      ),
      borderRadius: BorderRadius.circular(23),
      border: Border.all(color: const Color(0xFF8B8AFF).withValues(alpha: .22)),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF6366F1).withValues(alpha: .08),
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
                style: const TextStyle(
                  color: Color(0xFF9EACCC),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                context.strings.text('activation.price_confirmed'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                context.strings.text('activation.price_validated'),
                style: const TextStyle(
                  color: Color(0xFF9EACCC),
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.verified_outlined, color: Color(0xFF6EE7B7), size: 23),
      ],
    ),
  );

  Widget _buildPurchaseButton() {
    final selected = _selectedItem;
    final isProcessing = _ordering;

    return SizedBox(
      height: 60,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: selected == null || _loading || isProcessing
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
          boxShadow: selected == null || _loading || isProcessing
              ? const []
              : [
                  BoxShadow(
                    color: const Color(0xFF7657FF).withValues(alpha: .28),
                    blurRadius: 24,
                    offset: const Offset(0, 9),
                  ),
                ],
        ),
        child: ElevatedButton(
          onPressed: selected == null || _loading || isProcessing
              ? null
              : () => _order(selected),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white70,
            shadowColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(19),
            ),
          ),
          child: isProcessing
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 21,
                      height: 21,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Getting number...',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.bolt_rounded, size: 23),
                    const SizedBox(width: 9),
                    Text(
                      context.strings.text(
                        'activation.get_number',
                        variables: {'service': selected?.serviceName ?? ''},
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .4,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _countryFlag(Map<String, dynamic>? country) {
    final flag = '${country?['flag'] ?? ''}'.trim();
    final uri = Uri.tryParse(flag);
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      final isSvg = uri.path.toLowerCase().endsWith('.svg');
      return ClipRRect(
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
      );
    }
    if (flag.isNotEmpty && !flag.startsWith('http')) {
      return Text(flag, style: const TextStyle(fontSize: 25));
    }
    return const Icon(Icons.public_rounded, color: Color(0xFF93B4FF));
  }

  IconData _serviceIcon(String service) {
    switch (service.trim().toLowerCase()) {
      case 'telegram':
        return Icons.send_rounded;
      case 'instagram':
        return Icons.camera_alt_outlined;
      case 'facebook':
        return Icons.facebook_rounded;
      case 'tiktok':
        return Icons.music_note_rounded;
      case 'whatsapp':
        return Icons.chat_rounded;
      case 'gmail':
      case 'google':
        return Icons.mail_outline_rounded;
      case 'discord':
        return Icons.forum_outlined;
      default:
        return Icons.sms_rounded;
    }
  }

  Future<void> _showServiceSheet() async {
    _search.clear();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1428),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * .75,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.strings.text('tnum.title'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _search,
                        autofocus: false,
                        onChanged: (_) => setSheetState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: context.strings.text('tnum.search'),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Color(0xFFA5B4D0),
                          ),
                          filled: true,
                          fillColor: const Color(0xFF111A32),
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
                  child: _visibleServices.isEmpty
                      ? Center(
                          child: Text(
                            context.strings.text('tnum.empty'),
                            style: const TextStyle(color: Color(0xFFA5B4D0)),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                          itemCount: _visibleServices.length,
                          itemBuilder: (context, index) {
                            final item = _visibleServices[index];
                            final isSelected =
                                item.serviceSlug == _selectedServiceSlug;
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF111A32),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(
                                          0xFF4776FF,
                                        ).withValues(alpha: .55)
                                      : Colors.white.withValues(alpha: .07),
                                ),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: const Color(0xFF24345A),
                                  child: Icon(
                                    _serviceIcon(item.serviceName),
                                    color: const Color(0xFF93B4FF),
                                  ),
                                ),
                                title: Text(
                                  item.serviceName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.countryName} · ${item.availableCount}',
                                  style: const TextStyle(
                                    color: Color(0xFFA5B4D0),
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _money(item.customerPriceCents),
                                      style: const TextStyle(
                                        color: Color(0xFF6EE7B7),
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    if (isSelected)
                                      const Padding(
                                        padding: EdgeInsets.only(left: 8),
                                        child: Icon(
                                          Icons.check_circle_rounded,
                                          color: Color(0xFF6EE7B7),
                                          size: 19,
                                        ),
                                      ),
                                  ],
                                ),
                                onTap: () {
                                  setState(
                                    () =>
                                        _selectedServiceSlug = item.serviceSlug,
                                  );
                                  Navigator.pop(sheetContext);
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _search.clear();
  }

  Future<void> _showCountrySheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1428),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * .75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.strings.text('tnum.country'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  itemCount: _countries.length,
                  itemBuilder: (context, index) {
                    final country = _countries[index];
                    final code = int.tryParse('${country['code']}');
                    final selected = code == _countryCode;
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111A32),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF4776FF).withValues(alpha: .55)
                              : Colors.white.withValues(alpha: .07),
                        ),
                      ),
                      child: ListTile(
                        leading: _countryFlag(country),
                        title: Text(
                          '${country['name']}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        trailing: selected
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: Color(0xFF6EE7B7),
                              )
                            : null,
                        onTap: code == null
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _selectCountry(code);
                              },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOperations(
    List<Map<String, dynamic>> rows, {
    required bool history,
  }) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.strings.text(
                  history ? 'tnum.history' : 'tnum.active_title',
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showHistory = false),
              child: Text(context.strings.text('tnum.back')),
            ),
          ],
        ),
      ),
      Expanded(
        child: _historyLoading
            ? const Center(child: CircularProgressIndicator())
            : _historyError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    context.strings.text(_historyError!.messageKey),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFFFE2A5)),
                  ),
                ),
              )
            : rows.isEmpty
            ? Center(
                child: Text(
                  context.strings.text(
                    history ? 'tnum.history_empty' : 'tnum.no_active',
                  ),
                  style: const TextStyle(color: Color(0xFFA5B4D0)),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: rows
                    .map((row) => _activationCard(row, history: history))
                    .toList(),
              ),
      ),
    ],
  );

  Widget _activationCard(Map<String, dynamic> row, {required bool history}) {
    final service = Map<String, dynamic>.from(row['services'] as Map? ?? {});
    final country = Map<String, dynamic>.from(row['countries'] as Map? ?? {});
    final sms = (row['activation_sms'] as List? ?? [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    final id = '${row['id']}';
    final status = tnumStatusLabel(context, '${row['status'] ?? ''}');
    return Card(
      color: const Color(0xFF151D36),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetails(id),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${service['name'] ?? row['service_slug']}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    context.strings.text('tnum.origin'),
                    style: const TextStyle(
                      color: Color(0xFF8FB6FF),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${country['name'] ?? row['country_code']} · $status',
                style: const TextStyle(color: Color(0xFFA5B4D0)),
              ),
              if (row['phone_number'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${row['phone_number']}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              if (sms.isNotEmpty)
                ...sms.map(
                  (message) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${message['code'] ?? message['message_text']}',
                      style: const TextStyle(
                        color: Color(0xFF6EE7B7),
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${context.strings.text('tnum.customer_price')}: ${_money((row['customer_price_cents'] as num? ?? 0).toInt())}',
                  style: const TextStyle(color: Color(0xFFA5B4D0)),
                ),
              ),
              if (!history && status == 'sms_received')
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _action(id, false),
                      child: Text(context.strings.text('tnum.next_sms')),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _action(id, true),
                      child: Text(context.strings.text('tnum.complete')),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

