import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/localization/app_localizations.dart';
import '../../activate/data/tnum_repository.dart';
import '../../activate/data/tnum_activation.dart';
import '../../activate/widgets/tnum_feedback.dart';

class TnumOperationDetailsPage extends StatefulWidget {
  const TnumOperationDetailsPage({
    super.key,
    required this.activationId,
    this.repository,
    this.purchaseConfirmed = false,
  });
  final String activationId;
  final TnumRepository? repository;
  final bool purchaseConfirmed;

  @override
  State<TnumOperationDetailsPage> createState() =>
      _TnumOperationDetailsPageState();
}

class _TnumOperationDetailsPageState extends State<TnumOperationDetailsPage> {
  late final _repository = widget.repository ?? TnumRepository();
  late Future<Map<String, dynamic>> _detailsFuture;
  Timer? _remainingTimer;
  Timer? _syncTimer;
  RealtimeChannel? _activationChannel;
  int? _remainingSeconds;
  bool _actionBusy = false;
  bool _syncInFlight = false;
  bool _realtimeConnected = false;
  bool _backendReachable = true;
  bool _feedbackDialogOpen = false;
  Map<String, dynamic>? _lastActivation;

  @override
  void initState() {
    super.initState();
    _syncInFlight = true;
    _detailsFuture = _loadInitialDetails();
    _subscribeToActivation();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _syncFromBackend();
    });
  }

  Future<Map<String, dynamic>> _loadInitialDetails() async {
    try {
      return await _loadDetails();
    } catch (_) {
      _backendReachable = false;
      rethrow;
    } finally {
      _syncInFlight = false;
    }
  }

  @override
  void dispose() {
    _remainingTimer?.cancel();
    _syncTimer?.cancel();
    final channel = _activationChannel;
    if (channel != null) {
      unawaited(_repository.removeActivationWatch(channel));
    }
    super.dispose();
  }

  void _subscribeToActivation() {
    _activationChannel = _repository.watchActivation(
      widget.activationId,
      onChange: _syncFromBackend,
      onConnection: (connected) {
        if (!mounted) return;
        setState(() => _realtimeConnected = connected);
        if (connected) _syncFromBackend();
      },
    );
  }

  Future<Map<String, dynamic>> _loadDetails({
    bool refreshProvider = true,
  }) async {
    final activation = await _repository.details(
      widget.activationId,
      refreshProvider: refreshProvider,
    );
    final applicationDeadline = DateTime.tryParse(
      '${activation['deadline_at'] ?? ''}',
    );
    final remaining = applicationDeadline == null
        ? null
        : tnumApplicationRemainingSeconds(applicationDeadline);
    if (mounted) {
      setState(
        () => _remainingSeconds = remaining != null && remaining >= 0
            ? remaining
            : null,
      );
      _startRemainingTimer();
      _lastActivation = activation;
    }
    return activation;
  }

  void _startRemainingTimer() {
    _remainingTimer?.cancel();
    if (_remainingSeconds == null) return;
    _remainingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _remainingSeconds == null || _remainingSeconds! <= 0) {
        timer.cancel();
        return;
      }
      setState(() => _remainingSeconds = _remainingSeconds! - 1);
    });
  }

  Future<void> _refresh({bool refreshProvider = true}) async {
    if (_syncInFlight || _actionBusy) return;
    _syncInFlight = true;
    try {
      final future = _loadDetails(refreshProvider: refreshProvider);
      if (mounted) setState(() => _detailsFuture = future);
      await future;
      if (mounted) setState(() => _backendReachable = true);
    } catch (_) {
      if (mounted) setState(() => _backendReachable = false);
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _syncFromBackend() async {
    if (!mounted || _syncInFlight || _actionBusy) return;
    _syncInFlight = true;
    try {
      final future = _loadDetails(refreshProvider: false);
      if (mounted) setState(() => _detailsFuture = future);
      await future;
      if (mounted) setState(() => _backendReachable = true);
    } catch (_) {
      // Keep the last rendered activation while Realtime or the network recovers.
      if (mounted) setState(() => _backendReachable = false);
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required bool completing,
  }) async {
    if (_actionBusy) return;
    final priorSmsKeys = (_lastActivation?['activation_sms'] as List? ?? [])
        .whereType<Map>()
        .map((row) => _smsFingerprint(Map<String, dynamic>.from(row)))
        .toSet();
    setState(() => _actionBusy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) await _showFeedback(TnumFeedbackMessage.fromError(error));
      return;
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
    if (!mounted) return;
    await _refresh(refreshProvider: false);
    final activation = _lastActivation;
    if (activation == null) return;
    final status = '${activation['status'] ?? ''}';
    if (completing && status == 'completed') {
      await _showFeedback(
        const TnumFeedbackMessage(
          titleKey: 'tnum.feedback.completed_title',
          messageKey: 'tnum.feedback.completed_body',
          kind: TnumFeedbackKind.success,
        ),
      );
    } else if (!completing) {
      final sms = (activation['activation_sms'] as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) => !priorSmsKeys.contains(_smsFingerprint(row)))
          .toList();
      final lastSms = sms.isEmpty ? null : sms.last;
      final code = '${lastSms?['code'] ?? ''}'.trim();
      if (code.isNotEmpty && lastSms != null) {
        if (_feedbackDialogOpen) return;
        if (!mounted) return;
        final strings = context.strings;
        _feedbackDialogOpen = true;
        try {
          await TnumFeedbackDialog.show(
            context,
            title: strings.text('tnum.feedback.sms_received_title'),
            message: strings.text(
              'tnum.feedback.sms_received_body',
              variables: {
                'code': code,
                'message': '${lastSms['message_text'] ?? ''}'.trim(),
              },
            ),
            kind: TnumFeedbackKind.success,
          );
        } finally {
          _feedbackDialogOpen = false;
        }
      } else {
        await _showFeedback(
          const TnumFeedbackMessage(
            titleKey: 'tnum.feedback.processing_title',
            messageKey: 'tnum.feedback.next_sms_pending',
            kind: TnumFeedbackKind.info,
          ),
        );
      }
    }
  }

  String _smsFingerprint(Map<String, dynamic> message) =>
      '${message['id'] ?? message['provider_message_key'] ?? ''}|'
      '${message['provider_received_at'] ?? ''}|'
      '${message['code'] ?? ''}|${message['message_text'] ?? ''}';

  Future<void> _showFeedback(TnumFeedbackMessage message) async {
    if (!mounted || _feedbackDialogOpen) return;
    _feedbackDialogOpen = true;
    try {
      await TnumFeedbackDialog.show(
        context,
        title: context.strings.text(message.titleKey),
        message: context.strings.text(message.messageKey),
        kind: message.kind,
      );
    } finally {
      _feedbackDialogOpen = false;
    }
  }

  Future<void> _copy(String value) async {
    if (value.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.strings.text('tnum.details.copied'))),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.strings.text('tnum.origin')),
      actions: [
        IconButton(
          tooltip: context.strings.text('tnum.details.refresh'),
          onPressed: _actionBusy ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _detailsFuture,
      builder: (context, snapshot) {
        final activation = snapshot.data ?? _lastActivation;
        if (snapshot.hasError && activation == null) {
          return _loadError(context, snapshot.error!);
        }
        if (activation == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final service = Map<String, dynamic>.from(
          activation['services'] as Map? ?? const {},
        );
        final country = Map<String, dynamic>.from(
          activation['countries'] as Map? ?? const {},
        );
        final sms =
            (activation['activation_sms'] as List? ?? [])
                .map((row) => Map<String, dynamic>.from(row as Map))
                .toList()
              ..sort((a, b) => _messageDate(a).compareTo(_messageDate(b)));
        final status = '${activation['status'] ?? ''}';
        final phone = '${activation['phone_number'] ?? ''}'.trim();
        final providerState = Map<String, dynamic>.from(
          activation['_provider_state'] as Map? ?? const {},
        );
        final refreshFailed = activation['_provider_refresh_error'] == true;

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
    if (_isTerminalStatus(status)) ...[
      _terminalSummary(context, status, sms),
      const SizedBox(height: 16),
    ],
    _smsSection(context, sms, status),
            if (widget.purchaseConfirmed) ...[
              const SizedBox(height: 12),
              _purchaseConfirmation(context),
            ],
            const SizedBox(height: 16),
            if (refreshFailed) _refreshWarning(context),
            if (!_isTerminalStatus(status) &&
    (!_realtimeConnected || !_backendReachable))
  _connectionStatus(context),
            _numberCard(context, phone),
            const SizedBox(height: 16),
            _statusCard(context, activation, status, providerState),
            const SizedBox(height: 16),
            _heroCard(context, activation, service, country, status),
            const SizedBox(height: 18),
            _actions(context, activation, status, sms.isNotEmpty),
          ],
        );
      },
    ),
  );

  Widget _loadError(BuildContext context, Object error) {
    final message = TnumFeedbackMessage.fromError(error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: Color(0xFFA5B4D0),
              size: 42,
            ),
            const SizedBox(height: 12),
            Text(
              context.strings.text(message.messageKey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.strings.text('tnum.details.refresh')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _refreshWarning(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFF3A2A14),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFFFC857).withValues(alpha: .28)),
    ),
    child: Row(
      children: [
        const Icon(Icons.sync_problem_rounded, color: Color(0xFFFFC857)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            context.strings.text('tnum.details.refresh_failed'),
            style: const TextStyle(color: Color(0xFFFFE2A5), fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget _purchaseConfirmation(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF123228),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF34D399).withValues(alpha: .28)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_rounded, color: Color(0xFF34D399)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.strings.text('tnum.feedback.purchase_success_title'),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.strings.text('tnum.feedback.purchase_success_body'),
                style: const TextStyle(
                  color: Color(0xFFC7D2E8),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _connectionStatus(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        const Icon(Icons.sync_rounded, size: 16, color: Color(0xFFFFC857)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.strings.text('tnum.details.reconnecting'),
            style: const TextStyle(color: Color(0xFFFFE2A5), fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget _heroCard(
    BuildContext context,
    Map<String, dynamic> activation,
    Map<String, dynamic> service,
    Map<String, dynamic> country,
    String status,
  ) {
    final title = '${service['name'] ?? activation['service_slug']}';
    final countryName = '${country['name'] ?? activation['country_code']}';
    final countryMark = '${country['flag'] ?? country['emoji'] ?? ''}'.trim();
    final created = _formatDateTime(context, activation['created_at']);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF182448), Color(0xFF151A35), Color(0xFF21183D)],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: const Color(0xFF8B8AFF).withValues(alpha: .22),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: .08),
            blurRadius: 25,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF4776FF).withValues(alpha: .25),
                      const Color(0xFF8B5CF6).withValues(alpha: .18),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Icon(
                    _serviceIcon(title),
                    color: const Color(0xFFB7CCFF),
                    size: 27,
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        if (countryMark.isNotEmpty) ...[
                          Text(
                            countryMark,
                            style: const TextStyle(fontSize: 17),
                          ),
                          const SizedBox(width: 6),
                        ] else ...[
                          const Icon(
                            Icons.public_rounded,
                            color: Color(0xFF93B4FF),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            countryName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFA5B4D0),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          _statusChip(context, status),
          const SizedBox(height: 13),
          _metaLine(
            context,
            Icons.schedule_rounded,
            context.strings.text('tnum.details.created'),
            created,
          ),
          const SizedBox(height: 7),
          _metaLine(
            context,
            Icons.confirmation_number_outlined,
            context.strings.text('tnum.origin'),
            '${activation['provider_operation_id'] ?? '—'}',
          ),
        ],
      ),
    );
  }

  Widget _numberCard(BuildContext context, String phone) => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.strings.text('tnum.phone'),
          style: const TextStyle(
            color: Color(0xFFA5B4D0),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                phone.isEmpty
                    ? context.strings.text('tnum.details.number_unavailable')
                    : phone,
                style: TextStyle(
                  color: phone.isEmpty ? const Color(0xFFA5B4D0) : Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .3,
                ),
              ),
            ),
            if (phone.isNotEmpty)
              IconButton.filledTonal(
                tooltip: context.strings.text('tnum.details.copy_number'),
                onPressed: () => _copy(phone),
                icon: const Icon(Icons.copy_rounded),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _statusCard(
    BuildContext context,
    Map<String, dynamic> activation,
    String status,
    Map<String, dynamic> providerState,
  ) {
    final price = (activation['customer_price_cents'] as num? ?? 0).toInt();
    final providerTime = _remainingSeconds;
    final providerStatus =
        '${providerState['status'] ?? activation['provider_status'] ?? ''}';
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.strings.text('tnum.status'),
            style: const TextStyle(
              color: Color(0xFFA5B4D0),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
  Icons.circle,
  color: _statusColor(status),
  size: 9,
),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusText(context, status),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (providerStatus.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${tnumStatusLabel(context, providerStatus, providerStatus: true)} · ${context.strings.text('tnum.details.sms_status')}',
              style: const TextStyle(color: Color(0xFFA5B4D0), fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          const Divider(color: Color(0x1FFFFFFF), height: 1),
          const SizedBox(height: 12),
       Row(
  children: [
    Expanded(
      child: _metaLine(
        context,
        Icons.payments_outlined,
        context.strings.text('tnum.customer_price'),
        '\$${(price / 100).toStringAsFixed(2)}',
      ),
    ),
    if (!_isTerminalStatus(status)) ...[
      const SizedBox(width: 12),
      Expanded(
        child: _metaLine(
          context,
          Icons.hourglass_bottom_rounded,
          context.strings.text('tnum.details.remaining'),
          providerTime == null
              ? context.strings.text('tnum.details.no_provider_time')
              : _duration(providerTime),
        ),
      ),
    ],
  ],
),
        ],
      ),
    );
  }

  Widget _smsSection(
    BuildContext context,
    List<Map<String, dynamic>> messages,
    String status,
  ) {
    final received = messages
        .where((message) => _nonEmpty(message['message_text']))
        .toList();
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.mark_email_read_rounded,
                  color: Color(0xFF6EE7B7),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.strings.text('tnum.sms'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${received.length}',
                style: const TextStyle(
                  color: Color(0xFFA5B4D0),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (received.isEmpty)
            _waitingSms(context, status)
          else
            ...received.map((message) => _messageCard(context, message)),
        ],
      ),
    );
  }

  Widget _waitingSms(BuildContext context, String status) {
    final terminal = const {
      'completed',
      'expired',
      'cancelled',
      'failed',
    }.contains(status);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          terminal
              ? const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFF93B4FF),
                  size: 28,
                )
              : const _PulsingSmsIcon(),
          const SizedBox(height: 9),
          Text(
            terminal
                ? context.strings.text('tnum.details.empty_sms')
                : context.strings.text('tnum.details.waiting_title'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            terminal
                ? _statusText(context, status)
                : context.strings.text('tnum.details.waiting_body'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFA5B4D0),
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (!terminal && _remainingSeconds != null) ...[
            const SizedBox(height: 9),
            Text(
              _duration(_remainingSeconds!),
              style: const TextStyle(
                color: Color(0xFFB7CCFF),
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _messageCard(BuildContext context, Map<String, dynamic> message) {
    final code = '${message['code'] ?? ''}'.trim();
    final fullText = '${message['message_text'] ?? ''}'.trim();
    final sender = '${message['provider_sender'] ?? message['sender'] ?? ''}'
        .trim();
    final providerReceived = message['provider_received_at'];
    final recorded = message['received_at'];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF111A32),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF8294BD).withValues(alpha: .15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (code.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF182448), Color(0xFF21183D)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: context.strings.text('tnum.details.copy_code'),
                    onPressed: () => _copy(code),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ),
          if (code.isNotEmpty) const SizedBox(height: 13),
          Text(
            context.strings.text('tnum.details.full_message'),
            style: const TextStyle(
              color: Color(0xFFA5B4D0),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            fullText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          if (sender.isNotEmpty) ...[
            const SizedBox(height: 11),
            _metaLine(
              context,
              Icons.person_outline_rounded,
              context.strings.text('tnum.details.sender'),
              sender,
            ),
          ],
          if (providerReceived != null) ...[
            const SizedBox(height: 8),
            _metaLine(
              context,
              Icons.mark_email_read_outlined,
              context.strings.text('tnum.details.provider_received'),
              _formatDateTime(context, providerReceived),
            ),
          ],
          if (recorded != null) ...[
            const SizedBox(height: 8),
            _metaLine(
              context,
              Icons.save_outlined,
              context.strings.text('tnum.details.recorded_at'),
              _formatDateTime(context, recorded),
            ),
          ],
          if (code.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                context.strings.text('tnum.details.code_unavailable'),
                style: const TextStyle(color: Color(0xFFA5B4D0), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions(
    BuildContext context,
    Map<String, dynamic> activation,
    String status,
    bool hasSms,
  ) {
    final canUseSmsActions = status == 'sms_received' && hasSms && !_actionBusy;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 54,
          child: OutlinedButton.icon(
            onPressed: _actionBusy ? null : _refresh,
            icon: _actionBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            label: Text(
              context.strings.text(
                _actionBusy
                    ? 'tnum.details.refreshing'
                    : 'tnum.details.refresh',
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(
                color: const Color(0xFF8294BD).withValues(alpha: .3),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        if (canUseSmsActions) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _runAction(
                    () => _repository.nextSms('${activation['id']}'),
                    completing: false,
                  ),
                  icon: const Icon(Icons.mark_email_unread_outlined),
                  label: Text(context.strings.text('tnum.next_sms')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB7CCFF),
                    side: BorderSide(
                      color: const Color(0xFF8294BD).withValues(alpha: .25),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _runAction(
                    () => _repository.complete('${activation['id']}'),
                    completing: true,
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: Text(
                    context.strings.text('tnum.details.complete_activation'),
                  ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _statusChip(BuildContext context, String status) {
    final color = switch (status) {
      'active' || 'sms_received' => const Color(0xFF34D399),
      'expiration_pending' => const Color(0xFFFFC857),
      'expired' || 'cancelled' || 'failed' => const Color(0xFFFF8795),
      'completed' => const Color(0xFF93B4FF),
      _ => const Color(0xFFA5B4D0),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Text(
        _statusText(context, status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  String _statusText(BuildContext context, String status) {
    final key = switch (status) {
      'reserved' ||
      'purchase_pending' ||
      'provider_outcome_uncertain' => 'status_pending',
      'active' => 'status_active',
      'sms_received' || 'completion_pending' => 'status_sms_received',
      'expiration_pending' => 'status_expiration_pending',
      'expired' => 'status_expired',
      'cancelled' => 'status_cancelled',
      'completed' => 'status_completed',
      'failed' => 'status_failed',
      _ => null,
    };
    return key == null
        ? context.strings.text('tnum.details.provider_unconfirmed')
        : context.strings.text('tnum.details.$key');
  }

  bool _isTerminalStatus(String status) => const {
  'completed',
  'expired',
  'cancelled',
  'failed',
}.contains(status);

Color _statusColor(String status) => switch (status) {
  'completed' => const Color(0xFF34D399),
  'expired' => const Color(0xFFFFC857),
  'cancelled' || 'failed' => const Color(0xFFFF8795),
  'active' || 'sms_received' => const Color(0xFF34D399),
  'expiration_pending' => const Color(0xFFFFC857),
  _ => const Color(0xFF93B4FF),
};

IconData _statusIcon(String status) => switch (status) {
  'completed' => Icons.check_circle_rounded,
  'expired' => Icons.timer_off_rounded,
  'cancelled' => Icons.cancel_rounded,
  'failed' => Icons.error_rounded,
  _ => Icons.info_outline_rounded,
};

Widget _terminalSummary(
  BuildContext context,
  String status,
  List<Map<String, dynamic>> sms,
) {
  final color = _statusColor(status);
  final hasSms = sms.any(
    (message) => _nonEmpty(message['message_text']),
  );

  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: color.withValues(alpha: .30),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_statusIcon(status), color: color, size: 28),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                _statusText(context, status),
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          hasSms
              ? context.strings.text('tnum.sms')
              : context.strings.text('tnum.details.empty_sms'),
          style: const TextStyle(
            color: Color(0xFFC7D2E8),
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: const Color(0xFF111A32).withValues(alpha: .96),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF8294BD).withValues(alpha: .16)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .12),
          blurRadius: 18,
          offset: const Offset(0, 7),
        ),
      ],
    ),
    child: child,
  );

  Widget _metaLine(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: const Color(0xFF93B4FF), size: 16),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          '$label: $value',
          style: const TextStyle(
            color: Color(0xFFA5B4D0),
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ),
    ],
  );

  IconData _serviceIcon(String service) =>
      switch (service.trim().toLowerCase()) {
        'telegram' => Icons.send_rounded,
        'instagram' => Icons.camera_alt_outlined,
        'facebook' => Icons.facebook_rounded,
        'tiktok' => Icons.music_note_rounded,
        'whatsapp' => Icons.chat_rounded,
        'google' || 'gmail' => Icons.mail_outline_rounded,
        'discord' => Icons.forum_outlined,
        _ => Icons.sms_rounded,
      };

  bool _nonEmpty(Object? value) => value != null && '$value'.trim().isNotEmpty;

  DateTime _messageDate(Map<String, dynamic> message) =>
      DateTime.tryParse(
        '${message['provider_received_at'] ?? message['received_at'] ?? ''}',
      ) ??
      DateTime.fromMillisecondsSinceEpoch(0);

  String _formatDateTime(BuildContext context, Object? value) {
    final date = DateTime.tryParse('${value ?? ''}')?.toLocal();
    if (date == null) return '—';
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(date)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  String _duration(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final minutes = safe ~/ 60;
    final remainder = safe % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }
}

class _PulsingSmsIcon extends StatefulWidget {
  const _PulsingSmsIcon();

  @override
  State<_PulsingSmsIcon> createState() => _PulsingSmsIconState();
}

class _PulsingSmsIconState extends State<_PulsingSmsIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween<double>(
      begin: .86,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: const Icon(
      Icons.mark_email_unread_outlined,
      color: Color(0xFF93B4FF),
      size: 30,
    ),
  );
}
