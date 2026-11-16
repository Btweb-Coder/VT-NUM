import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/localization/app_localizations.dart';
import '../../../app/theme/colors.dart';
import '../data/tnum_repository.dart';

enum TnumFeedbackKind { success, warning, error, info }

class TnumFeedbackMessage {
  const TnumFeedbackMessage({
    required this.titleKey,
    required this.messageKey,
    this.kind = TnumFeedbackKind.error,
  });

  final String titleKey;
  final String messageKey;
  final TnumFeedbackKind kind;

  factory TnumFeedbackMessage.fromError(Object error) {
    final code = error is TnumRepositoryException
        ? error.code.toUpperCase()
        : error is TimeoutException
        ? 'NETWORK_TIMEOUT'
        : 'TNUM_REQUEST_FAILED';
    return switch (code) {
      'INSUFFICIENT_FUNDS' ||
      'INSUFFICIENT_BALANCE' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.insufficient_title',
        messageKey: 'tnum.feedback.insufficient_body',
      ),
      'PROVIDER_NO_NUMBER' ||
      'PROVIDER_ERROR_NO_SERVICE' ||
      'PROVIDER_UNDEFINED_COUNTRY' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.unavailable_title',
        messageKey: 'tnum.feedback.no_number',
      ),
      'PRICE_CHANGED' || 'QUOTE_EXPIRED' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.price_title',
        messageKey: 'tnum.feedback.price_body',
        kind: TnumFeedbackKind.warning,
      ),
      'PENDING_PROVIDER_OPERATION' ||
      'PROVIDER_OUTCOME_UNCERTAIN' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.processing_title',
        messageKey: 'tnum.feedback.uncertain_body',
        kind: TnumFeedbackKind.info,
      ),
      'REQUEST_RATE_LIMIT' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.processing_title',
        messageKey: 'tnum.feedback.rate_limit',
        kind: TnumFeedbackKind.warning,
      ),
      'NETWORK_TIMEOUT' || 'NETWORK_CONNECTION' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.connection_title',
        messageKey: 'tnum.feedback.connection_body',
        kind: TnumFeedbackKind.warning,
      ),
      'PROVIDER_TEMPORARILY_UNAVAILABLE' ||
      'PROVIDER_UNAVAILABLE' ||
      'PROVIDER_TIMEOUT' ||
      'PROVIDER_NETWORK_ERROR' ||
      'PROVIDER_INVALID_RESPONSE' ||
      'PROVIDER_WARNING_LOW_BALANCE' ||
      'PROVIDER_ACCOUNT_BLOCKED' ||
      'PROVIDER_API_ACCESS_DISABLED' ||
      'PROVIDER_API_ACCESS_IP' ||
      'PROVIDER_ERROR_WRONG_KEY' ||
      'PROVIDER_ERROR_NO_KEY' ||
      'PROVIDER_INTERVAL_CONCURRENT_REQUESTS_ERROR' ||
      'PRICING_UNAVAILABLE' ||
      'CATALOG_UNAVAILABLE' ||
      'FUNCTION_UNAVAILABLE' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.server_title',
        messageKey: 'tnum.feedback.server_body',
        kind: TnumFeedbackKind.warning,
      ),
      'PROVIDER_REQUEST_NOT_FOUND' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.verification_title',
        messageKey: 'tnum.feedback.uncertain_body',
        kind: TnumFeedbackKind.info,
      ),
      'AUTH_REQUIRED' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.session_title',
        messageKey: 'tnum.feedback.session_body',
      ),
      'INVALID_REQUEST' ||
      'INVALID_ID' ||
      'INVALID_JSON' ||
      'PAYLOAD_TOO_LARGE' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.validation_title',
        messageKey: 'tnum.feedback.validation_body',
      ),
      'COUNTRY_REQUIRED' ||
      'COUNTRY_NOT_IN_PROVIDER_CATALOG' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.unavailable_title',
        messageKey: 'tnum.feedback.catalog_unavailable',
        kind: TnumFeedbackKind.warning,
      ),
      'SMS_NOT_AVAILABLE' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.code_pending_title',
        messageKey: 'tnum.feedback.code_pending_body',
        kind: TnumFeedbackKind.info,
      ),
      'ACTIVATION_NOT_FOUND' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.activation_unavailable_title',
        messageKey: 'tnum.feedback.activation_unavailable_body',
      ),
      'SMS_REQUIRED_BEFORE_COMPLETION' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.code_pending_title',
        messageKey: 'tnum.feedback.complete_requires_sms',
        kind: TnumFeedbackKind.info,
      ),
      'COMPLETION_ALREADY_PROCESSING' ||
      'PROVIDER_PROTECTIVE_INTERVAL' => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.processing_title',
        messageKey: 'tnum.feedback.action_processing',
        kind: TnumFeedbackKind.info,
      ),
      _ => const TnumFeedbackMessage(
        titleKey: 'tnum.feedback.unknown_title',
        messageKey: 'tnum.feedback.unknown_body',
      ),
    };
  }
}

class TnumFeedbackDialog {
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String message,
    TnumFeedbackKind kind = TnumFeedbackKind.error,
    String? actionLabel,
    VoidCallback? onAction,
  }) async {
    final (icon, color) = switch (kind) {
      TnumFeedbackKind.success => (
        Icons.check_circle_rounded,
        AppColors.success,
      ),
      TnumFeedbackKind.warning => (
        Icons.warning_amber_rounded,
        AppColors.warning,
      ),
      TnumFeedbackKind.info => (Icons.info_outline_rounded, AppColors.primary),
      TnumFeedbackKind.error => (Icons.error_rounded, AppColors.error),
    };
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          if (actionLabel != null && onAction != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                onAction();
              },
              child: Text(actionLabel),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.strings.text('common.confirm')),
          ),
        ],
      ),
    );
  }
}

extension TnumFeedbackLocalization on TnumFeedbackMessage {
  Future<void> show(BuildContext context) => TnumFeedbackDialog.show(
    context,
    title: context.strings.text(titleKey),
    message: context.strings.text(messageKey),
    kind: kind,
  );
}

String tnumStatusLabel(
  BuildContext context,
  String status, {
  bool providerStatus = false,
}) {
  final normalized = providerStatus
      ? switch (status) {
          'TZ_INPOOL' || 'TZ_NUM_WAIT' => 'active',
          'TZ_NUM_ANSWER' => 'sms_received',
          'TZ_OVER_EMPTY' => 'expired',
          'TZ_OVER_OK' => 'completed',
          _ => 'unconfirmed',
        }
      : switch (status) {
          'reserved' ||
          'purchase_pending' ||
          'provider_outcome_uncertain' => 'pending',
          'active' => 'active',
          'sms_received' || 'completion_pending' => 'sms_received',
          'expiration_pending' => 'expiration_pending',
          'expired' => 'expired',
          'cancelled' => 'cancelled',
          'completed' => 'completed',
          'failed' => 'failed',
          _ => 'unconfirmed',
        };
  final key = switch (normalized) {
    'pending' => 'tnum.details.status_pending',
    'active' => 'tnum.details.status_active',
    'sms_received' => 'tnum.details.status_sms_received',
    'expiration_pending' => 'tnum.details.status_expiration_pending',
    'expired' => 'tnum.details.status_expired',
    'cancelled' => 'tnum.details.status_cancelled',
    'completed' => 'tnum.details.status_completed',
    'failed' => 'tnum.details.status_failed',
    _ => 'tnum.details.provider_unconfirmed',
  };
  return context.strings.text(key);
}
