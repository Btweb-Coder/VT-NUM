import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../app/localization/app_localizations.dart';
import '../../app/theme/colors.dart';
import '../models/activation.dart';

class ActivationCard extends StatelessWidget {
  final Activation activation;

  final VoidCallback? onCancel;
  final VoidCallback? onGetAnotherNumber;

  const ActivationCard({
    super.key,
    required this.activation,
    this.onCancel,
    this.onGetAnotherNumber,
  });

  @override
  Widget build(BuildContext context) {
    final isReplaced = activation.wasReplaced;
final isExpired = activation.isExpired && !isReplaced;
final hasCode = activation.hasCode && !isReplaced;
final isProcessing = activation.isProcessing && !isReplaced;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: hasCode
              ? AppColors.success.withValues(alpha: .35)
              : isExpired
                  ? AppColors.warning.withValues(alpha: .35)
                  : AppColors.border,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .15),
            blurRadius: 25,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          _header(
            context,
            isReplaced: isReplaced,
            isExpired: isExpired,
            hasCode: hasCode,
          ),

          const SizedBox(height: 20),

          _phoneNumber(context),

          const SizedBox(height: 20),

          if (isReplaced) ...[
  _replacedSection(context),
] else if (hasCode) ...[
  _codeSection(context),
] else if (isExpired) ...[
  _expiredSection(context),
] else ...[
  _waitingSection(context),
],

          const SizedBox(height: 18),

          _priceAndCountry(context),

          // IMPORTANT:
          // The action buttons ONLY exist when expired.
          if (isExpired && !isReplaced) ...[
            const SizedBox(height: 18),

            _expiredActions(
              context,
              disabled: isProcessing,
            ),
          ],

          // Processing state after the user has pressed
          // CANCEL or GET ANOTHER NUMBER.
          if (isProcessing && !isReplaced) ...[
            const SizedBox(height: 18),
            _processingState(context),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // HEADER  _header()
  // ============================================================

  Widget _header(BuildContext context, {
    required bool isExpired,
    required bool hasCode,
    required bool isReplaced,
  }) {
    return Row(
      children: [
        Container(
          width: 45,
          height: 45,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            _serviceIcon(),
            color: AppColors.primary,
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                activation.service,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Row(
  children: [
    _countryFlag(),
    const SizedBox(width: 6),
    Expanded(
      child: Text(
        activation.country,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
    ),
  ],
),
            ],
          ),
        ),

       _statusBadge(
         context,
  isExpired: isExpired,
  hasCode: hasCode,
  isReplaced: isReplaced,
),
      ],
    );
  }


Widget _countryFlag() {
  final flag = activation.countryFlag.trim();

  if (flag.isEmpty) {
    return const Icon(
      Icons.public,
      size: 18,
      color: AppColors.textMuted,
    );
  }

  if (flag.startsWith('http://') ||
      flag.startsWith('https://')) {
    if (flag.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        flag,
        width: 24,
        height: 18,
        placeholderBuilder: (_) => const SizedBox(
          width: 24,
          height: 18,
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }

    return Image.network(
      flag,
      width: 24,
      height: 18,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const Icon(
        Icons.public,
        size: 18,
        color: AppColors.textMuted,
      ),
    );
  }

  // Si la valeur est déjà un emoji, on l'affiche directement.
  return Text(
    flag,
    style: const TextStyle(fontSize: 18),
  );
}

Widget _statusBadge(BuildContext context, {
  required bool isExpired,
  required bool hasCode,
  required bool isReplaced,
}) {
  late String label;
  late Color color;

  if (isReplaced) {
    label = context.strings.text('activation_card.status.replaced');
    color = AppColors.textMuted;
  } else if (hasCode) {
    label = context.strings.text('activation_card.status.code_received');
    color = AppColors.success;
  } else if (isExpired) {
    label = context.strings.text('activation_card.status.expired');
    color = AppColors.warning;
  } else if (activation.status == ActivationStatus.cancelling) {
    label = context.strings.text('activation_card.status.cancelling');
    color = AppColors.error;
  } else if (activation.status == ActivationStatus.replacing) {
    label = context.strings.text('activation_card.status.replacing');
    color = AppColors.primary;
  } else {
    label = context.strings.text('activation_card.status.waiting');
    color = AppColors.primary;
  }

  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: 10,
      vertical: 6,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}


  // ============================================================
  // NUMBER
  // ============================================================

  Widget _phoneNumber(BuildContext context) {
    return Column(
      children: [
        Text(
          context.strings.text('activation_card.number_title'),
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          activation.phoneNumber,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // WAITING
  // ============================================================

  Widget _waitingSection(BuildContext context) {
    final remaining = activation.remainingSeconds;

    final progress = (remaining / Activation.applicationTimeoutSeconds)
        .clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              ),
              SizedBox(width: 10),
              Text(
                context.strings.text('activation_card.waiting'),
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),

          const SizedBox(height: 15),

          Text(
            _formatTime(remaining),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 12),

          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor:
                  Colors.white.withValues(alpha: .05),
              valueColor:
                  const AlwaysStoppedAnimation(
                AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // EXPIRED
  // ============================================================

  Widget _replacedSection(BuildContext context) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: AppColors.border,
      ),
    ),
    child: Column(
      children: [
        Icon(
          Icons.swap_horiz_rounded,
          color: AppColors.textMuted,
          size: 28,
        ),
        SizedBox(height: 10),
        Text(
          context.strings.text('activation_card.replaced_title'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: 5),
        Text(
          context.strings.text('activation_card.replaced_message'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

  Widget _expiredSection(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: .15),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.timer_off_outlined,
            color: AppColors.warning,
            size: 28,
          ),
          SizedBox(height: 10),
          Text(
            context.strings.text('activation_card.expired_title'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 5),
          Text(
            context.strings.text('activation_card.expired_message'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CODE
  // ============================================================

  Widget _codeSection(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            AppColors.success,
            Color(0xFF16A34A),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            context.strings.text('activation_card.code_title'),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            activation.code ?? '------',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              letterSpacing: 6,
            ),
          ),

          const SizedBox(height: 14),

          SizedBox(
            width: double.infinity,
            height: 45,
            child: ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(
                    text: activation.code ?? '',
                  ),
                );

                ScaffoldMessenger.of(context)
                    .showSnackBar(
                  SnackBar(
                    content: Text(
                      context.strings.text('activation_card.code_copied'),
                    ),
                  ),
                );
              },
              icon: const Icon(
                Icons.copy,
                size: 17,
              ),
              label: Text(
                context.strings.text('activation_card.copy_code').toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.success,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // PRICE / COUNTRY
  // ============================================================

  Widget _priceAndCountry(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _info(
            icon: Icons.public,
            title: context.strings.text('activation_card.country'),
            value: activation.country,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _info(
            icon: Icons.payments_outlined,
            title: context.strings.text('activation_card.price'),
            value:
                '${activation.price} '
                '${activation.currency}',
          ),
        ),
      ],
    );
  }

  Widget _info({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .025),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 17,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // EXPIRED ACTIONS
  // ============================================================

  Widget _expiredActions(BuildContext context, {
    required bool disabled,
  }) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: disabled ? null : onCancel,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              disabledForegroundColor:
                  AppColors.textMuted,
              side: BorderSide(
                color: disabled
                    ? AppColors.border
                    : AppColors.error
                        .withValues(alpha: .45),
              ),
              minimumSize:
                  const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(14),
              ),
            ),
            child: Text(
              context.strings.text('common.cancel').toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ),

        const SizedBox(width: 10),

        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed:
                disabled ? null : onGetAnotherNumber,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  AppColors.surfaceLight,
              disabledForegroundColor:
                  AppColors.textMuted,
              minimumSize:
                  const Size.fromHeight(48),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(14),
              ),
            ),
            child: Text(
              context.strings.text('activation_card.another_number').toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // PROCESSING
  // ============================================================

  Widget _processingState(BuildContext context) {
    String message;

    if (activation.status ==
        ActivationStatus.cancelling) {
      message = context.strings.text('activation_card.cancelling');
    } else if (activation.status ==
        ActivationStatus.replacing) {
      message = context.strings.text('activation_card.searching_number');
    } else {
      message = context.strings.text('activation_card.processing');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 17,
            height: 17,
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            message,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  String _formatTime(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  IconData _serviceIcon() {
    switch (activation.service) {
      case 'Telegram':
        return Icons.send;
      case 'Instagram':
        return Icons.camera_alt_outlined;
      case 'Facebook':
        return Icons.facebook;
      case 'TikTok':
        return Icons.music_note;
      default:
        return Icons.chat;
    }
  }
}


//isReplaced: isReplaced, '${activation.countryFlag} 
