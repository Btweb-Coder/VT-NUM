import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/localization/app_localizations.dart';
import '../data/referral_repository.dart';

class ReferralPage extends StatefulWidget {
  const ReferralPage({super.key});

  @override
  State<ReferralPage> createState() => _ReferralPageState();
}

class _ReferralPageState extends State<ReferralPage> {
  final _repository = ReferralRepository();
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = const {};

  String t(String key, {Map<String, Object?> variables = const {}}) =>
      context.strings.text('referral.' + key, variables: variables);

  double value(String key) => (_data[key] as num?)?.toDouble() ?? 0;
  double? get rate => (_data['usd_to_xaf_rate'] as num?)?.toDouble();
  String money(double amount) => '\$' + amount.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final data = await _repository.getDashboard();
      if (!mounted) return;
      setState(() { _data = data; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _error = t('load_error'); _loading = false; });
    }
  }

  Future<void> _copy({required bool codeOnly}) async {
    final code = _data['referral_code'] as String?;
    if (code == null || code.isEmpty) return;
    final text = codeOnly ? code : t('invite_message', variables: {'code': code});
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('copied'))));
  }

  void _history(bool withdrawals) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _HistorySheet(
        repository: _repository,
        withdrawals: withdrawals,
        text: (key) => ctx.strings.text('referral.' + key),
      ),
    );
  }

  Future<void> _withdraw() async {
    final exchangeRate = rate;
    if (exchangeRate == null || exchangeRate <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('rate_unavailable'))));
      return;
    }
    final input = await showDialog<_WithdrawalInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WithdrawalDialog(
        minimum: value('minimum_withdrawal_usd'),
        maximum: value('maximum_withdrawal_usd'),
        available: value('available_balance_usd'),
        rate: exchangeRate,
        text: t,
      ),
    );
    if (input == null || !mounted) return;
    try {
      await _repository.requestWithdrawal(
        amountUsd: input.amount,
        network: input.network,
        accountName: input.name,
        phoneNumber: input.phone,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('withdrawal_submitted'))));
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().contains('INSUFFICIENT_REFERRAL_BALANCE')
          ? t('insufficient_balance')
          : error.toString().contains('WITHDRAWAL_AMOUNT_OUT_OF_RANGE')
              ? t('amount_out_of_range')
              : t('withdrawal_error');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = _data['code_unlocked'] == true;
    final code = _data['referral_code'] as String?;
    final available = value('available_balance_usd');
    final minimum = value('minimum_withdrawal_usd');
    final exchangeRateReady = rate != null && rate! > 0;

    return Scaffold(
      backgroundColor: const Color(0xFF050816),
      appBar: AppBar(
        title: Text(t('title'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF7EA8FF)))
          : _error != null
              ? _ErrorState(message: _error!, retry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFF7EA8FF),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
                    children: [
                      _hero(unlocked, code),
                      const SizedBox(height: 20),
                      _section(t('overview')),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _stat(t('total_earned'), money(value('total_earned_usd')), Icons.trending_up_rounded)),
                        const SizedBox(width: 12),
                        Expanded(child: _stat(t('available_balance'), money(available), Icons.account_balance_wallet_outlined)),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _stat(t('total_withdrawn'), money(value('total_withdrawn_usd')), Icons.payments_outlined)),
                        const SizedBox(width: 12),
                        Expanded(child: _stat(t('successful_deposits'), (_data['successful_deposits'] ?? 0).toString(), Icons.receipt_long_outlined)),
                      ]),
                      const SizedBox(height: 12),
                      _stat(t('referred_users'), (_data['referred_users'] ?? 0).toString(), Icons.people_alt_outlined, wide: true),
                      const SizedBox(height: 22),
                      _section(t('withdrawals')),
                      const SizedBox(height: 12),
                      _panel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t('withdrawal_rules', variables: {
                              'min': money(minimum),
                              'max': money(value('maximum_withdrawal_usd')),
                            }), style: const TextStyle(color: Color(0xFFC3CEE7), fontSize: 12, height: 1.55)),
                            if (!exchangeRateReady) ...[
                              const SizedBox(height: 10),
                              Text(t('rate_unavailable'), style: const TextStyle(color: Color(0xFFFFC978), fontSize: 12)),
                            ],
                            const SizedBox(height: 15),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: available >= minimum && exchangeRateReady ? _withdraw : null,
                                icon: const Icon(Icons.account_balance_outlined),
                                label: Text(t('request_withdrawal')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF3978F6),
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: Colors.white12,
                                  disabledForegroundColor: Colors.white38,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                ),
                              ),
                            ),
                            if (available < minimum) ...[
                              const SizedBox(height: 8),
                              Text(t('minimum_balance_hint', variables: {'amount': money(minimum)}),
                                  style: const TextStyle(color: Color(0xFF8291B0), fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      _section(t('history')),
                      const SizedBox(height: 12),
                      _historyButton(Icons.people_outline_rounded, t('referral_history'), t('referral_history_subtitle'), () => _history(false)),
                      const SizedBox(height: 10),
                      _historyButton(Icons.receipt_long_rounded, t('withdrawal_history'), t('withdrawal_history_subtitle'), () => _history(true)),
                    ],
                  ),
                ),
    );
  }

  Widget _hero(bool unlocked, String? code) {
    final count = (_data['eligible_activations'] as num?)?.toInt() ?? 0;
    final progress = (count / 2).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2D59), Color(0xFF20204C), Color(0xFF321F55)],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [BoxShadow(color: const Color(0xFF526BFF).withValues(alpha: 0.12), blurRadius: 28, offset: const Offset(0, 12))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(15)),
              child: const Icon(Icons.card_giftcard_rounded, color: Color(0xFFB9D1FF), size: 24),
            ),
            const SizedBox(width: 13),
            Expanded(child: Text(t('hero_title'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900))),
            const Icon(Icons.auto_awesome_rounded, color: Color(0xFFFFD58A)),
          ]),
          const SizedBox(height: 14),
          Text(t('hero_subtitle', variables: {'commission': money(value('commission_per_deposit_usd'))}),
              style: const TextStyle(color: Color(0xFFC8D3F1), fontSize: 12, height: 1.55)),
          const SizedBox(height: 18),
          if (unlocked && code != null) ...[
            Text(t('your_code'), style: const TextStyle(color: Color(0xFFB9C8EA), fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.20), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withValues(alpha: 0.10))),
              child: Row(children: [
                Expanded(child: SelectableText(code, style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 2, fontWeight: FontWeight.w900))),
                IconButton(tooltip: t('copy_code'), onPressed: () => _copy(codeOnly: true), icon: const Icon(Icons.copy_rounded, color: Colors.white)),
              ]),
            ),
            const SizedBox(height: 11),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _copy(codeOnly: false),
                icon: const Icon(Icons.share_outlined),
                label: Text(t('copy_invite')),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: BorderSide(color: Colors.white.withValues(alpha: 0.28)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13))),
              ),
            ),
          ] else ...[
            Row(children: [
              Expanded(child: Text(t('unlock_progress', variables: {'count': count.toString()}), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
              Text(count.clamp(0, 2).toString() + '/2', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: Colors.white.withValues(alpha: 0.14), valueColor: const AlwaysStoppedAnimation(Color(0xFF7DD3FC))),
            ),
            const SizedBox(height: 9),
            Text(t('unlock_hint'), style: const TextStyle(color: Color(0xFFB9C8EA), fontSize: 11, height: 1.5)),
          ],
        ],
      ),
    );
  }

  Widget _section(String text) => Text(text.toUpperCase(), style: const TextStyle(color: Color(0xFF8998B7), fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4));

  Widget _stat(String title, String amount, IconData icon, {bool wide = false}) => Container(
        width: wide ? double.infinity : null,
        padding: const EdgeInsets.all(15),
        decoration: _decoration(),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFF5A82F4).withValues(alpha: 0.13), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: const Color(0xFF9EBBFF), size: 20)),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF8998B7), fontSize: 10, height: 1.3)),
            const SizedBox(height: 5),
            Text(amount, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
          ])),
        ]),
      );

  Widget _historyButton(IconData icon, String title, String subtitle, VoidCallback onTap) => Container(
        decoration: _decoration(),
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
          leading: Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFF5A82F4).withValues(alpha: 0.13), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: const Color(0xFF9EBBFF))),
          title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
          subtitle: Text(subtitle, style: const TextStyle(color: Color(0xFF8998B7), fontSize: 11)),
          trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
        ),
      );

  Widget _panel({required Widget child}) => Container(padding: const EdgeInsets.all(17), decoration: _decoration(), child: child);

  BoxDecoration _decoration() => BoxDecoration(
        color: const Color(0xFF111A32).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, color: Color(0xFFFF8585), size: 40),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: retry, child: Text(context.strings.text('common.retry'))),
          ]),
        ),
      );
}

class _WithdrawalInput {
  const _WithdrawalInput({required this.amount, required this.network, required this.name, required this.phone});
  final double amount;
  final String network;
  final String name;
  final String phone;
}

class _WithdrawalDialog extends StatefulWidget {
  const _WithdrawalDialog({required this.minimum, required this.maximum, required this.available, required this.rate, required this.text});
  final double minimum;
  final double maximum;
  final double available;
  final double rate;
  final String Function(String, {Map<String, Object?> variables}) text;

  @override
  State<_WithdrawalDialog> createState() => _WithdrawalDialogState();
}

class _WithdrawalDialogState extends State<_WithdrawalDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String _network = 'MTN_MOMO';

  @override
  void dispose() {
    _amount.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  double get _amountValue => double.tryParse(_amount.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF111A32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(widget.text('withdrawal_form_title'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.text('available_amount', variables: {'amount': '\$' + widget.available.toStringAsFixed(2)}), style: const TextStyle(color: Color(0xFF9EBBFF), fontSize: 12)),
              const SizedBox(height: 15),
              _field(_amount, widget.text('amount_usd'), (v) {
                final n = double.tryParse(v?.trim() ?? '');
                if (n == null || n <= 0) return widget.text('invalid_amount');
                if (n < widget.minimum || n > widget.maximum) return widget.text('amount_out_of_range');
                if ((n * 100 - (n * 100).round()).abs() > 0.000001) return widget.text('invalid_amount');
                if (n > widget.available) return widget.text('insufficient_balance');
                return null;
              }, keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {})),
              const SizedBox(height: 7),
              Text(widget.text('xaf_estimate', variables: {'amount': (_amountValue * widget.rate).toStringAsFixed(0)}), style: const TextStyle(color: Color(0xFF9EBBFF), fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 13),
              DropdownButtonFormField<String>(
                value: _network,
                dropdownColor: const Color(0xFF1A2542),
                decoration: _inputDecoration(widget.text('mobile_money_network')),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: [
                  DropdownMenuItem(value: 'MTN_MOMO', child: Text(widget.text('mtn_momo'))),
                  DropdownMenuItem(value: 'ORANGE_MONEY', child: Text(widget.text('orange_money'))),
                ],
                onChanged: (v) => setState(() => _network = v ?? 'MTN_MOMO'),
              ),
              const SizedBox(height: 13),
              _field(_name, widget.text('account_holder'), (v) => (v?.trim().length ?? 0) >= 2 ? null : widget.text('required_field'), keyboard: TextInputType.name),
              const SizedBox(height: 13),
              _field(_phone, widget.text('mobile_money_number'), (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                return digits.length >= 8 && digits.length <= 16 ? null : widget.text('invalid_phone');
              }, keyboard: TextInputType.phone),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.text('cancel'), style: const TextStyle(color: Colors.white60))),
          ElevatedButton(
            onPressed: () {
              if (!(_formKey.currentState?.validate() ?? false)) return;
              Navigator.pop(context, _WithdrawalInput(amount: _amountValue, network: _network, name: _name.text.trim(), phone: _phone.text.trim()));
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3978F6), foregroundColor: Colors.white),
            child: Text(widget.text('submit')),
          ),
        ],
      );

  Widget _field(TextEditingController controller, String label, String? Function(String?) validator, {TextInputType keyboard = TextInputType.text, ValueChanged<String>? onChanged}) => TextFormField(
        controller: controller,
        keyboardType: keyboard,
        onChanged: onChanged,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: _inputDecoration(label),
        validator: validator,
      );

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF9AAED3), fontSize: 12),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.035),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: Color(0xFF83B6FF))),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: Color(0xFFE5484D))),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: Color(0xFFE5484D))),
      );
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({
    required this.repository,
    required this.withdrawals,
    required this.text,
  });

  final ReferralRepository repository;
  final bool withdrawals;
  final String Function(String) text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.78,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: Color(0xFF101522),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text(withdrawals ? 'withdrawal_history' : 'referral_history'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<Map<String, dynamic>>(
              future: repository.getHistory(limit: 100),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF7EA8FF)),
                  );
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return Center(
                    child: Text(
                      text('history_error'),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  );
                }

                final data = snapshot.data!;
                if (withdrawals) {
                  final raw = data['withdrawals'];
                  final items = raw is List ? raw : const [];
                  if (items.isEmpty) return _empty();
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, index) {
                      final item = Map<String, dynamic>.from(items[index] as Map);
                      return _withdrawalRow(item);
                    },
                  );
                }

                final referralsRaw = data['referrals'];
                final commissionsRaw = data['commission_events'];
                final referrals = referralsRaw is List ? referralsRaw : const [];
                final commissions =
                    commissionsRaw is List ? commissionsRaw : const [];
                if (referrals.isEmpty && commissions.isEmpty) return _empty();

                return ListView(
                  children: [
                    _heading(text('referral_history')),
                    if (referrals.isEmpty)
                      _emptyInline()
                    else
                      ...referrals.map((raw) => _referralRow(
                            Map<String, dynamic>.from(raw as Map),
                          )),
                    const SizedBox(height: 14),
                    _heading(text('commission_activity')),
                    if (commissions.isEmpty)
                      _emptyInline()
                    else
                      ...commissions.map((raw) => _commissionRow(
                            Map<String, dynamic>.from(raw as Map),
                          )),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Center(
        child: Text(
          text('history_empty'),
          style: const TextStyle(color: Color(0xFF8998B7)),
        ),
      );

  Widget _emptyInline() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          text('history_empty'),
          style: const TextStyle(color: Color(0xFF8998B7), fontSize: 11),
        ),
      );

  Widget _heading(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF8998B7),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
      );

  String _shortUserId(Object? raw) {
    final id = (raw ?? '').toString();
    return id.length > 12 ? id.substring(0, 8) + '…' : id;
  }

  Widget _referralRow(Map<String, dynamic> item) {
    final depositCount = (item['successful_deposits'] ?? 0).toString();
    final commission = ((item['commission_usd'] as num?) ?? 0)
        .toStringAsFixed(2);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 3),
      leading: const CircleAvatar(
        backgroundColor: Color(0xFF202F55),
        child: Icon(Icons.person_outline_rounded, color: Color(0xFF9EBBFF)),
      ),
      title: Text(
        _shortUserId(item['user_id']),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        text('deposits') + ': ' + depositCount +
            ' • ' + text('joined') + ': ' + _date(item['joined_at']),
        style: const TextStyle(color: Color(0xFF8998B7), fontSize: 10),
      ),
      trailing: Text(
        '\$' + commission,
        style: const TextStyle(
          color: Color(0xFF6EE7B7),
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _commissionRow(Map<String, dynamic> item) {
    final amount = ((item['amount_usd'] as num?) ?? 0).toStringAsFixed(2);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(
        Icons.check_circle_outline_rounded,
        color: Color(0xFF6EE7B7),
      ),
      title: Text(
        text('deposit_reward') + ' • ' + _shortUserId(item['referee_user_id']),
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
      subtitle: Text(
        _date(item['created_at']),
        style: const TextStyle(color: Color(0xFF8998B7), fontSize: 10),
      ),
      trailing: Text(
        '+\$' + amount,
        style: const TextStyle(
          color: Color(0xFF6EE7B7),
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _withdrawalRow(Map<String, dynamic> item) {
    final status = (item['status'] ?? '').toString();
    final color = status == 'PAID'
        ? const Color(0xFF6EE7B7)
        : status == 'REJECTED'
            ? const Color(0xFFFF8585)
            : const Color(0xFFFFD58A);
    final reason = item['rejection_reason']?.toString() ?? '';
    final paymentRef = item['payment_reference']?.toString() ?? '';
    final accountName = item['account_name']?.toString() ?? '';
    final phone = item['phone_number']?.toString() ?? '';
    final network = item['network'] == 'MTN_MOMO'
        ? text('mtn_momo')
        : text('orange_money');
    final amount = ((item['amount_usd'] as num?) ?? 0).toStringAsFixed(2);
    final xaf = ((item['amount_xaf'] as num?) ?? 0).toStringAsFixed(0);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 5),
      leading: Icon(Icons.account_balance_wallet_outlined, color: color),
      title: Text(
        '\$' + amount + ' • ' + xaf + ' FCFA',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            network + ' • ' + phone +
                (accountName.isEmpty ? '' : ' • ' + accountName),
            style: const TextStyle(color: Color(0xFFB7C7E5), fontSize: 10),
          ),
          Text(
            text('status') + ': ' + text(status.toLowerCase()) +
                ' • ' + text('requested') + ': ' + _date(item['created_at']),
            style: const TextStyle(color: Color(0xFF8998B7), fontSize: 10),
          ),
          if (reason.isNotEmpty)
            Text(
              text('rejection_reason') + ': ' + reason,
              style: const TextStyle(color: Color(0xFFFF8585), fontSize: 10),
            ),
          if (paymentRef.isNotEmpty)
            Text(
              text('payment_reference') + ': ' + paymentRef,
              style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 10),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: Text(
        status,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900),
      ),
    );
  }

  String _date(Object? input) {
    if (input == null) return '—';
    final date = DateTime.tryParse(input.toString());
    if (date == null) return '—';
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return day + '/' + month + '/' + local.year.toString();
  }
}
