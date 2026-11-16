import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme/colors.dart';
import '../../../app/localization/app_localizations.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/services/wallet_ledger_repository.dart';
import '../data/payment_gateway_repository.dart';
import '../data/top_up_repository.dart';

class WalletPage extends StatefulWidget {
  const WalletPage({super.key, this.openTopUpOnStart = false});

  final bool openTopUpOnStart;

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  @override
  void initState() {
    super.initState();

    if (widget.openTopUpOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showTopUpSheet();
        }
      });
    }
  }

  final _topUps = TopUpRepository();
  late final Future<List<WalletLedgerEntry>> _ledger = WalletLedgerRepository()
      .loadRecent();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.text('wallet.title'))),
    body: StreamBuilder<WalletSnapshot?>(
      stream: WalletRepository().watchWallet(),
      builder: (context, walletSnapshot) {
        if (walletSnapshot.hasError)
          return Center(child: Text(context.strings.text('wallet.load_error')));
        if (!walletSnapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final wallet = walletSnapshot.data;
        if (wallet == null)
          return Center(
            child: Text(context.strings.text('wallet.initializing')),
          );
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(25),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.violet],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.strings.text('wallet.available_balance')),
                  const SizedBox(height: 8),
                  Text(
                    '\$${wallet.available.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.strings.text(
                      'wallet.held_balance',
                      variables: {
                        'amount': wallet.held.toStringAsFixed(0),
                        'currency': wallet.currency,
                      },
                    ),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                onPressed: _showTopUpSheet,
                icon: const Icon(Icons.account_balance_wallet, size: 23),
                label: Text(
                  context.strings.text('wallet.add_funds').toUpperCase(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 5,
                  shadowColor: AppColors.primary.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),
            Text(
              context.strings.text('wallet.recent_topups'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            StreamBuilder<List<TopUpIntent>>(
              stream: _topUps.watchRecent(),
              builder: (context, snapshot) {
                if (!snapshot.hasData)
                  return Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  );
                if (snapshot.data!.isEmpty)
                  return Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(context.strings.text('wallet.no_topups')),
                  );
                return Column(
                  children: snapshot.data!.map(_intentTile).toList(),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              context.strings.text('wallet.financial_history'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            FutureBuilder<List<WalletLedgerEntry>>(
              future: _ledger,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Text(context.strings.text('wallet.history_error'));
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                if (snapshot.data!.isEmpty)
                  return Text(context.strings.text('wallet.history_empty'));
                return Column(
                  children: snapshot.data!.map(_ledgerTile).toList(),
                );
              },
            ),
          ],
        );
      },
    ),
  );

  Widget _ledgerTile(WalletLedgerEntry entry) => Card(
    child: ListTile(
      leading: Icon(switch (entry.type) {
        'HOLD' => Icons.lock_outline,
        'RELEASE_HOLD' => Icons.lock_open,
        'CAPTURE_HOLD' => Icons.check_circle_outline,
        'DEPOSIT' => Icons.add_circle_outline,
        _ => Icons.receipt_long_outlined,
      }),
      title: Text(
        context.strings.text(
          'wallet.ledger_entry',
          variables: {'origin': entry.origin, 'operation': entry.type},
        ),
      ),
      subtitle: Text(entry.createdAt.toLocal().toString().substring(0, 16)),
      trailing: Text('${entry.amount.toStringAsFixed(2)} ${entry.currency}'),
    ),
  );

  Widget _intentTile(TopUpIntent intent) {
    final successful = intent.status == 'SUCCESSFUL';
    final failed = intent.status == 'FAILED';
    final color = successful
        ? AppColors.success
        : failed
        ? AppColors.error
        : AppColors.warning;
    final subtitle = failed
        ? context.strings.text(
            'wallet.failure',
            variables: {
              'code':
                  intent.failureCode ?? context.strings.text('wallet.unknown'),
            },
          )
        : intent.status == 'REQUIRES_RECONCILIATION'
        ? context.strings.text('wallet.reconciliation')
        : intent.status == 'PENDING'
        ? context.strings.text('wallet.pending')
        : intent.status;
    return Card(
      child: ListTile(
        leading: Icon(
          successful
              ? Icons.check_circle
              : failed
              ? Icons.error_outline
              : Icons.hourglass_top,
          color: color,
        ),
        title: Text(
          context.strings.text(
            'wallet.intent_summary',
            variables: {
              'amount': intent.amount,
              'currency': intent.currency,
              'gateway': intent.gateway.toUpperCase(),
            },
          ),
        ),
        subtitle: Text(subtitle),
        trailing: intent.status == 'PENDING'
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (intent.checkoutUrl != null)
                    IconButton(
                      icon: const Icon(Icons.open_in_new),
                      tooltip: context.strings.text('wallet.open_payment'),
                      onPressed: () => _openCheckout(intent.checkoutUrl!),
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: context.strings.text('wallet.check_payment'),
                    onPressed: () => _refresh(intent.id),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Future<void> _refresh(String intentId) async {
    try {
      await _topUps.refresh(intentId);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('wallet.check_error'))),
        );
    }
  }

  Future<void> _openCheckout(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('wallet.open_error'))),
        );
    }
  }

Future<void> _showTopUpSheet() async {
  await FirstTimeAppGuide.showIfNeeded(context, 'topup');
  if (!mounted) return;
  final preparingMessage =
      context.strings.text('wallet.preparing');

  final amount = TextEditingController();
  final phone = TextEditingController();
  final idempotencyKey = const Uuid().v4();

    var gateways = <PaymentGateway>[];
    var medium = 'mobile money';
    TopUpLimits? topUpLimits;

    try {
      gateways = await PaymentGatewayRepository().loadActive();
      topUpLimits = await _topUps.loadLimits();
    } catch (e, stackTrace) {
      debugPrint('========== TOP-UP INITIALIZATION ERROR ==========');
      debugPrint('Error type: ${e.runtimeType}');
      debugPrint('Error details: $e');
      debugPrintStack(stackTrace: stackTrace);
      debugPrint('==================================================');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 15),
            content: Text('Erreur de recharge (${e.runtimeType}): $e'),
          ),
        );
      }

      amount.dispose();
      phone.dispose();
      return;
    }

    if (gateways.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('wallet.no_gateways'))),
        );
      }
      amount.dispose();
      phone.dispose();
      return;
    }

    var gateway = gateways.first.slug;
    final formKey = GlobalKey<FormState>();

    var submitting = false;
    var checkingStatus = false;
    var timedOut = false;
var remainingSeconds = 600;
var waitingMessage = preparingMessage;

    TopUpIntent? activeIntent;
    Timer? countdownTimer;
    Timer? pollTimer;

    String? terminalMessage;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final intent = activeIntent;
          final status = intent?.status.toUpperCase() ?? '';

          final selectedGateway = gateways.firstWhere(
            (item) => item.slug == gateway,
          );

          final enteredAmount = int.tryParse(amount.text);
          final exchangeRate = selectedGateway.exchangeRate;
          final providerCurrency = selectedGateway.providerCurrency ?? '';

          final fee = enteredAmount != null
              ? (enteredAmount * topUpLimits!.feePercent * 100).round() / 100
              : null;

          final providerAmount =
              enteredAmount != null &&
                  fee != null &&
                  exchangeRate != null &&
                  exchangeRate > 0
              ? ((enteredAmount + fee) * exchangeRate).ceil()
              : null;

          Future<void> checkStatus({bool manual = false}) async {
            if (activeIntent == null || checkingStatus) return;

            checkingStatus = true;
            setSheetState(() {});

            try {
              final updated = await _topUps.refresh(activeIntent!.id);

              if (!sheetContext.mounted) return;

              activeIntent = updated;
              final currentStatus = updated.status.toUpperCase();

              if (currentStatus == 'SUCCESSFUL') {
                terminalMessage = context.strings.text(
                  'wallet.payment_confirmed',
                );
              } else if ([
                'FAILED',
                'CANCELLED',
                'CANCELED',
                'EXPIRED',
              ].contains(currentStatus)) {
                terminalMessage = switch (currentStatus) {
                  'CANCELLED' || 'CANCELED' => context.strings.text(
                    'wallet.payment_cancelled',
                  ),
                  'EXPIRED' => context.strings.text('wallet.payment_expired'),
                  _ => context.strings.text('wallet.payment_declined'),
                };
              } else if (currentStatus == 'REQUIRES_RECONCILIATION') {
                timedOut = true;
                waitingMessage = context.strings.text(
                  'wallet.reconciliation_message',
                );
                countdownTimer?.cancel();
                pollTimer?.cancel();
              } else if (manual && timedOut) {
                waitingMessage = context.strings.text('wallet.still_pending');
              }
            } catch (_) {
              if (sheetContext.mounted && manual) {
                ScaffoldMessenger.of(sheetContext).showSnackBar(
                  SnackBar(
                    content: Text(context.strings.text('wallet.check_later')),
                  ),
                );
              }
            } finally {
              checkingStatus = false;

              final message = terminalMessage;

              if (message != null) {
                countdownTimer?.cancel();
                pollTimer?.cancel();

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!sheetContext.mounted) return;

                  Navigator.of(sheetContext).pop();

                  if (mounted) {
                    ScaffoldMessenger.of(
                      this.context,
                    ).showSnackBar(SnackBar(content: Text(message)));
                  }
                });
              } else if (sheetContext.mounted) {
                setSheetState(() {});
              }
            }
          }

          void startWaitingSession() {
            countdownTimer?.cancel();
            pollTimer?.cancel();

            timedOut = false;
            remainingSeconds = 600;

            countdownTimer = Timer.periodic(const Duration(seconds: 1), (
              timer,
            ) {
              if (!sheetContext.mounted || timedOut) {
                timer.cancel();
                return;
              }

              if (remainingSeconds <= 1) {
                timer.cancel();
                pollTimer?.cancel();

                setSheetState(() {
                  remainingSeconds = 0;
                  timedOut = true;
                  waitingMessage = context.strings.text('wallet.timed_out');
                });
              } else {
                setSheetState(() => remainingSeconds--);
              }
            });

            pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
              if (!timedOut && !checkingStatus) {
                checkStatus();
              }
            });
          }

          final minutes = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
          final seconds = (remainingSeconds % 60).toString().padLeft(2, '0');

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.viewInsetsOf(context).bottom + 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.strings.text('wallet.add_funds'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),

                      Text(
                        context.strings.text(
                          'wallet.min_max',
                          variables: {
                            'min': topUpLimits!.minimum.toStringAsFixed(0),
                            'max': topUpLimits.maximum.toStringAsFixed(0),
                          },
                        ),
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 16),

                      DropdownButtonFormField<String>(
                        initialValue: gateway,
                        items: gateways
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.slug,

                                child: Row(
                                  children: [
                                    if (item.slug == 'fapshi')
                                      Image.asset(
                                        'assets/gateways/fapshi_logo.png',
                                        width: 32,
                                        height: 32,
                                        fit: BoxFit.contain,
                                      )
                                    else if (item.slug == 'transfluo')
                                      Image.asset(
                                        'assets/gateways/transfluo_logo.webp',
                                        width: 32,
                                        height: 32,
                                        fit: BoxFit.contain,
                                      )
                                    else
                                      const Icon(
                                        Icons.account_balance,
                                        size: 28,
                                      ),

                                    const SizedBox(width: 12),
                                    Text(
                                      item.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: activeIntent != null || submitting
                            ? null
                            : (value) {
                                if (value != null) {
                                  setSheetState(() => gateway = value);
                                }
                              },
                       decoration: InputDecoration(
  labelText: context.strings.text('wallet.gateway'),
  helperText: gateway == 'transfluo'
      ? context.strings.text('wallet.transfluo_mtn_only')
      : null,
),
                      ),

                      TextFormField(
                        controller: amount,
                        enabled: activeIntent == null && !submitting,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setSheetState(() {}),
                        decoration: InputDecoration(
                          labelText: context.strings.text('wallet.amount_usd'),
                        ),
                        validator: (value) {
                          final parsed = int.tryParse(value ?? '');

                          if (parsed == null) {
                            return context.strings.text(
                              'wallet.amount_integer_error',
                            );
                          }

                          if (parsed < topUpLimits!.minimum) {
                            return context.strings.text(
                              'wallet.minimum_error',
                              variables: {
                                'amount': topUpLimits.minimum.toStringAsFixed(
                                  0,
                                ),
                              },
                            );
                          }

                          if (parsed > topUpLimits.maximum) {
                            return context.strings.text(
                              'wallet.maximum_error',
                              variables: {
                                'amount': topUpLimits.maximum.toStringAsFixed(
                                  0,
                                ),
                              },
                            );
                          }

                          return null;
                        },
                      ),

                      const SizedBox(height: 16),

                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.strings
                                  .text('wallet.summary')
                                  .toUpperCase(),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.strings.text(
                                    'wallet.amount_to_credit',
                                  ),
                                ),
                                Text(
                                  enteredAmount != null
                                      ? '\$${enteredAmount.toStringAsFixed(2)}'
                                      : '—',
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(context.strings.text('wallet.fees')),
                                Text(
                                  fee != null
                                      ? '\$${fee.toStringAsFixed(2)}'
                                      : '—',
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.strings.text('wallet.exchange_rate'),
                                ),
                                Flexible(
                                  child: Text(
                                    exchangeRate != null && exchangeRate > 0
                                        ? context.strings.text(
                                            'wallet.rate',
                                            variables: {
                                              'rate': exchangeRate
                                                  .toStringAsFixed(2),
                                              'currency': providerCurrency,
                                            },
                                          )
                                        : context.strings.text(
                                            'common.unavailable',
                                          ),
                                    textAlign: TextAlign.end,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 24),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    context.strings
                                        .text('wallet.total')
                                        .toUpperCase(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    providerAmount != null
                                        ? context.strings.text(
                                            'wallet.provider_amount',
                                            variables: {
                                              'amount': providerAmount
                                                  .toString(),
                                              'currency': providerCurrency,
                                            },
                                          )
                                        : context.strings.text(
                                            'wallet.amount_invalid',
                                          ),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: AppColors.primary,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              context.strings.text('wallet.fee_estimate'),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: phone,
                        enabled: activeIntent == null && !submitting,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: context.strings.text(
                            'wallet.mobile_number',
                          ),
                          helperText: gateway == 'fapshi'
                              ? context.strings.text(
                                  'wallet.phone_helper_digits',
                                )
                              : gateway == 'transfluo'
                              ? context.strings.text(
                                  'wallet.phone_helper_prefix',
                                )
                              : null,
                        ),
                        validator: (value) {
                          final digits = (value ?? '').replaceAll(
                            RegExp(r'\D'),
                            '',
                          );

                          if (gateway == 'fapshi' || gateway == 'transfluo') {
                            final local = digits.startsWith('237')
                                ? digits.substring(3)
                                : digits;

                            return RegExp(r'^6\d{8}$').hasMatch(local)
                                ? null
                                : context.strings.text(
                                    'wallet.invalid_cameroon_number',
                                  );
                          }

                          return RegExp(r'^[0-9]{8,16}$').hasMatch(digits)
                              ? null
                              : context.strings.text('wallet.invalid_number');
                        },
                      ),

                      const SizedBox(height: 17),

                      if (gateway == 'fapshi') ...[
                        DropdownButtonFormField<String>(
                          initialValue: medium,
                          decoration: InputDecoration(
                            labelText: context.strings.text(
                              'wallet.mobile_network',
                            ),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'mobile money',
                              child: Text(context.strings.text('wallet.mtn')),
                            ),
                            DropdownMenuItem(
                              value: 'orange money',
                              child: Text(
                                context.strings.text('wallet.orange'),
                              ),
                            ),
                          ],
                          onChanged: activeIntent != null || submitting
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setSheetState(() => medium = value);
                                  }
                                },
                        ),
                        const SizedBox(height: 12),
                      ],

                      if (intent != null) ...[
                        const Divider(height: 28),
                        Text(
                          context.strings.text('wallet.payment_tracking'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(waitingMessage),

                        if (!timedOut) ...[
                          const SizedBox(height: 12),
                          Text(
                            '$minutes:$seconds',
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(context.strings.text('wallet.time_remaining')),
                        ],

                        const SizedBox(height: 8),
                        Text(
                          context.strings.text(
                            'wallet.status',
                            variables: {'status': status},
                          ),
                        ),

                        if (timedOut ||
                            status == 'REQUIRES_RECONCILIATION') ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: checkingStatus
                                  ? null
                                  : () => checkStatus(manual: true),
                              child: Text(
                                checkingStatus
                                    ? context.strings.text('wallet.checking')
                                    : context.strings.text(
                                        'wallet.check_status',
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ],

                      const SizedBox(height: 16),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: submitting || activeIntent != null
                              ? null
                              : () async {
                                  if (!(formKey.currentState?.validate() ??
                                      false)) {
                                    return;
                                  }

                                  setSheetState(() => submitting = true);

                                  try {
                                    final started = await _topUps.start(
                                      gateway: gateway,
                                      amount: int.parse(amount.text),
                                      phone: phone.text,
                                      idempotencyKey: idempotencyKey,
                                      medium: gateway == 'fapshi'
                                          ? medium
                                          : null,
                                    );

                                    if (!sheetContext.mounted) return;

                                    activeIntent = started;
                                    setSheetState(() {});

                                    final startedStatus = started.status
                                        .toUpperCase();

                                    if (startedStatus == 'SUCCESSFUL') {
                                      terminalMessage = context.strings.text(
                                        'wallet.topup_success',
                                      );
                                      Navigator.of(sheetContext).pop();

                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          this.context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(terminalMessage!),
                                          ),
                                        );
                                      }
                                      return;
                                    }

                                    if ([
                                      'FAILED',
                                      'CANCELLED',
                                      'CANCELED',
                                      'EXPIRED',
                                    ].contains(startedStatus)) {
                                      terminalMessage = context.strings.text(
                                        'wallet.payment_failed_status',
                                        variables: {'status': startedStatus},
                                      );
                                      Navigator.of(sheetContext).pop();

                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          this.context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(terminalMessage!),
                                          ),
                                        );
                                      }
                                      return;
                                    }

                                    startWaitingSession();
                                    setSheetState(() {
                                      waitingMessage = context.strings.text(
                                        'wallet.validate_payment',
                                      );
                                    });

                                    if (started.checkoutUrl != null) {
                                      await _openCheckout(started.checkoutUrl!);
                                    } else if (mounted) {
                                      ScaffoldMessenger.of(
                                        this.context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            context.strings.text(
                                              'wallet.confirm_on_phone',
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                  } catch (_) {
                                    if (sheetContext.mounted) {
                                      ScaffoldMessenger.of(
                                        sheetContext,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            sheetContext.strings.text(
                                              'wallet.start_error',
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (sheetContext.mounted) {
                                      setSheetState(() => submitting = false);
                                    }
                                  }
                                },

                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(58),
                            elevation: 5,
                            shadowColor: AppColors.primary.withValues(
                              alpha: 0.35,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),

                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (submitting) ...[
                                const SizedBox(
                                  width: 19,
                                  height: 19,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 10),
                              ] else ...[
                                Icon(
                                  activeIntent != null
                                      ? Icons.hourglass_top
                                      : Icons.lock_outline,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                              ],
                              Flexible(
                                child: Text(
                                  submitting
                                      ? context.strings.text('wallet.starting')
                                      : activeIntent != null
                                      ? context.strings.text(
                                          'wallet.payment_in_progress',
                                        )
                                      : context.strings.text(
                                          'wallet.request_payment',
                                        ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: Text(sheetContext.strings.text('common.close')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    countdownTimer?.cancel();
    pollTimer?.cancel();
  }
}


// transfluo