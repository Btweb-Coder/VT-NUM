import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FirstTimeAppGuide {
  FirstTimeAppGuide._();

  static const pendingPreferenceKey =
      'online_sim_first_time_guide_pending';
  static const registeredPreferenceKey =
      'online_sim_first_time_guide_registered';
  static const _sections = <String>[
    'auth', 'home', 'activate', 'active', 'history', 'topup',
  ];
  static final Set<String> _showing = <String>{};
  static final Map<String, GlobalKey> _anchorKeys = <String, GlobalKey>{};
  static final Map<String, VoidCallback> _revealCallbacks =
      <String, VoidCallback>{};

  /// Registers a screen-specific fallback for lazy scroll children that have
  /// not been built yet. The guide invokes it only when an anchor is missing.
  static void registerReveal(String section, VoidCallback reveal) {
    _revealCallbacks[section] = reveal;
  }

  static void unregisterReveal(String section) {
    _revealCallbacks.remove(section);
  }

  /// Stable anchors shared by the app screens and the first-time guide.
  static GlobalKey anchorKey(String section, String target) {
    final id = '$section::$target';
    return _anchorKeys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: 'first-time-guide-$id'),
    );
  }

  static Widget anchor(String section, String target, Widget child) {
    return KeyedSubtree(
      key: anchorKey(section, target),
      child: child,
    );
  }
  static Completer<void>? _registrationCompletion;

  static String _doneKey(String section) =>
      'online_sim_first_time_guide_done_' + section;

  static Future<bool> isPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(pendingPreferenceKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isSectionCompleted(String section) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_doneKey(section)) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> wasRegisteredOnThisInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(registeredPreferenceKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static void beginRegistrationAttempt() {
    _registrationCompletion = Completer<void>();
  }

  static Future<void> markRegistrationCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(registeredPreferenceKey, true);
    } catch (_) {
      // A local guide preference must never block account registration.
    } finally {
      _finishRegistrationAttempt();
    }
  }

  static void endRegistrationAttempt() {
    _finishRegistrationAttempt();
  }

  static void _finishRegistrationAttempt() {
    final completion = _registrationCompletion;
    _registrationCompletion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }

  static Future<void> handleSignInSuccess() async {
    final registrationCompletion = _registrationCompletion;
    if (registrationCompletion != null) {
      await registrationCompletion.future;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final registered = prefs.getBool(registeredPreferenceKey) ?? false;
      if (!registered) {
        // Existing accounts on a new installation should not receive the new-user tour.
        await prefs.setBool(pendingPreferenceKey, false);
      }
    } catch (_) {
      // Guide preferences are optional and never affect authentication.
    }
  }

  static Future<void> showIfNeeded(
    BuildContext context,
    String section, {
    ValueChanged<String>? onStepChanged,
  }) async {
    if (!_sections.contains(section) || _showing.contains(section)) return;
    _showing.add(section);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!context.mounted ||
          prefs.getBool(pendingPreferenceKey) != true ||
          prefs.getBool(_doneKey(section)) == true) {
        return;
      }
      if (section != 'auth' &&
          prefs.getBool(registeredPreferenceKey) != true) {
        return;
      }

      final french =
          Localizations.localeOf(context).languageCode.toLowerCase() == 'fr';
      final result = await _showSpotlightGuide(
        context,
        section: section,
        french: french,
        steps: _steps(section),
        onStepChanged: onStepChanged,
      );

      if (result == _GuideResult.skipAll) {
        await prefs.setBool(pendingPreferenceKey, false);
        return;
      }
      if (result == _GuideResult.finished) {
        await prefs.setBool(_doneKey(section), true);
        if (_sections.every((item) => prefs.getBool(_doneKey(item)) == true)) {
          await prefs.setBool(pendingPreferenceKey, false);
        }
      }
    } catch (_) {
      // A guide error must never prevent normal app access or transactions.
    } finally {
      _showing.remove(section);
    }
  }

  static List<_GuideStep> _steps(String section) {
    switch (section) {
      case 'auth':
        return const [
          _GuideStep('ACCOUNT ENTRY', 'ACCÈS AU COMPTE',
            'Welcome to VT-NUM', 'Bienvenue sur VT-NUM',
            'If this is your first account, stay on Create account. If you already have an account, use the Log in option at the bottom.',
            'Pour créer votre premier compte, restez sur Créer un compte. Si vous avez déjà un compte, utilisez Se connecter en bas.'),
          _GuideStep('EMAIL FIELD', 'CHAMP E-MAIL',
            'Enter your email', 'Entrez votre e-mail',
            'Type an email address you can open. Check that it is correct because account instructions may be sent there.',
            'Saisissez une adresse e-mail à laquelle vous avez accès. Vérifiez-la, car les instructions du compte peuvent y être envoyées.'),
          _GuideStep('PASSWORD FIELD', 'CHAMP MOT DE PASSE',
            'Choose a password', 'Choisissez un mot de passe',
            'Create a password with at least 8 characters. Keep it secret. Use the eye icon to show or hide what you typed.',
            'Créez un mot de passe d’au moins 8 caractères. Gardez-le secret. Utilisez l’œil pour afficher ou masquer votre saisie.'),
          _GuideStep('REFERRAL CODE (OPTIONAL)', 'CODE DE PARRAINAGE (FACULTATIF)',
            'Referral code', 'Code de parrainage',
            'Enter a referral code only if somebody gave you one. This field is optional. You can leave it empty.',
            'Saisissez un code de parrainage uniquement si quelqu’un vous en a donné un. Ce champ est facultatif. Vous pouvez le laisser vide.'),
          _GuideStep('TERMS CHECKBOX', 'CASE DES CONDITIONS',
            'Accept the terms', 'Acceptez les conditions',
            'During registration, tick this box to confirm that you accept the terms. You can open the terms link to read them first.',
            'Lors de l’inscription, cochez cette case pour accepter les conditions. Vous pouvez ouvrir le lien pour les lire avant.'),
          _GuideStep('CREATE ACCOUNT / LOG IN', 'CRÉER UN COMPTE / SE CONNECTER',
            'Finish creating your account', 'Terminez la création du compte',
            'When you are ready, use Create account once. Follow the email verification instructions, then return and choose Log in. Existing users can switch to Log in at the bottom.',
            'Lorsque vous êtes prêt, utilisez Créer un compte une seule fois. Suivez les instructions de vérification reçues par e-mail, puis revenez choisir Se connecter. Les utilisateurs déjà inscrits peuvent choisir Se connecter en bas.',
            allowTargetInteraction: false),
        ];
      case 'home':
        return const [
          _GuideStep('AVAILABLE BALANCE', 'SOLDE DISPONIBLE',
            'Your wallet balance', 'Le solde de votre portefeuille',
            'This is the amount available for new activations. Money reserved for an operation may appear separately as held balance.',
            'C’est le montant disponible pour de nouvelles activations. L’argent réservé pour une opération peut apparaître séparément comme solde bloqué.'),
          _GuideStep('ADD FUNDS', 'RECHARGER',
            'Recharge when needed', 'Rechargez si nécessaire',
            'Use Add funds to open your wallet and make a recharge. You need enough available balance before requesting a number.',
            'Utilisez Recharger pour ouvrir votre portefeuille et effectuer un dépôt. Votre solde disponible doit être suffisant avant de demander un numéro.'),
          _GuideStep('QUICK SERVICES', 'SERVICES RAPIDES',
            'Start with a service', 'Commencez par un service',
            'These shortcuts take you to activation. You can choose VT-NUM or T-NUM on the activation screen.',
            'Ces raccourcis ouvrent l’activation. Vous pourrez choisir VT-NUM ou T-NUM sur l’écran d’activation.'),
          _GuideStep('ACTIVE ACTIVATIONS', 'ACTIVATIONS EN COURS',
            'Follow your active numbers', 'Suivez vos numéros actifs',
            'This section gives a quick view of ongoing operations. Open Active in the bottom menu to follow a number and wait for its SMS.',
            'Cette section donne un aperçu des opérations en cours. Ouvrez Actives dans le menu du bas pour suivre un numéro et attendre son SMS.'),
          _GuideStep('RECENT ACTIVITY', 'ACTIVITÉ RÉCENTE',
            'Find your previous operations', 'Retrouvez vos opérations',
            'Your recent activity is shown here. Open History in the bottom menu to review VT-NUM and T-NUM activation records.',
            'Vos activités récentes apparaissent ici. Ouvrez Historique dans le menu du bas pour consulter vos activations VT-NUM et T-NUM.'),
        ];
      case 'activate':
        return const [
          _GuideStep('VT-NUM / T-NUM', 'VT-NUM / T-NUM',
            'Two ways to activate', 'Deux façons d’activer',
            'Choose Server 1 for VT-NUM or Server 2 for T-NUM. Both systems provide virtual numbers for receiving verification SMS.',
            'Choisissez Server 1 pour VT-NUM ou Server 2 pour T-NUM. Les deux systèmes fournissent des numéros virtuels pour recevoir des SMS de vérification.'),
          _GuideStep('VT-NUM: SERVICE', 'VT-NUM : SERVICE',
            'Choose the service', 'Choisissez le service',
            'With VT-NUM, tap the service selector and choose the app or website asking you to verify a phone number.',
            'Avec VT-NUM, touchez le sélecteur de service et choisissez l’application ou le site qui demande une vérification par numéro.'),
          _GuideStep('VT-NUM: COUNTRY', 'VT-NUM : PAYS',
            'Choose the country', 'Choisissez le pays',
            'Tap the country selector and choose the country of the virtual number you want to use.',
            'Touchez le sélecteur de pays et choisissez le pays du numéro virtuel que vous souhaitez utiliser.'),
          _GuideStep('VT-NUM: DISPLAYED PRICE', 'VT-NUM : PRIX AFFICHÉ',
            'Check the price', 'Vérifiez le prix',
            'Read the displayed customer price before continuing. Your available wallet balance must cover this price.',
            'Lisez le prix client affiché avant de continuer. Votre solde disponible doit couvrir ce prix.'),
          _GuideStep('GET NUMBER', 'OBTENIR UN NUMÉRO',
            'Request the number', 'Demandez le numéro',
            'When you are ready to request a number, tap Get number and read the confirmation carefully. Confirm only if the service, country and price are correct. Do not tap repeatedly while the request is processing.',
            'Lorsque vous êtes prêt à demander un numéro, touchez Obtenir un numéro et lisez attentivement la confirmation. Confirmez uniquement si le service, le pays et le prix sont corrects. Ne touchez pas plusieurs fois pendant le traitement.',
            allowTargetInteraction: false),
          _GuideStep('T-NUM: COUNTRY AND SERVICE', 'T-NUM : PAYS ET SERVICE',
            'Choose with T-NUM', 'Choisissez avec T-NUM',
            'Switch to Server 2. Choose the country, then select the service from the available list. Use the search field to find a service faster.',
            'Passez à Server 2. Choisissez le pays, puis le service dans la liste proposée. Utilisez la recherche pour trouver le service plus rapidement.'),
          _GuideStep('T-NUM: PRICE AND PURCHASE', 'T-NUM : PRIX ET ACHAT',
            'Review before buying', 'Vérifiez avant l’achat',
            'Check the displayed customer price. When you are ready, use the purchase button and confirm the price in the confirmation window to request the number.',
            'Vérifiez le prix client affiché. Lorsque vous êtes prêt, utilisez le bouton d’achat et confirmez le prix dans la fenêtre de confirmation pour demander le numéro.',
            allowTargetInteraction: false),
          _GuideStep('NUMBER AND SMS', 'NUMÉRO ET SMS',
            'Receive your verification code', 'Recevez votre code de vérification',
            'After a T-NUM purchase, your activation appears in this section. Open it to follow the number and SMS status. Copy the code when it arrives.',
            'Après un achat T-NUM, votre activation apparaît dans cette section. Ouvrez-la pour suivre le numéro et le statut du SMS. Copiez le code dès son arrivée.',
            allowTargetInteraction: false),
          _GuideStep('VT-NUM: DISPLAYED PRICE', 'VT-NUM : PRIX AFFICHÉ',
            'What if your balance is too low?', 'Que faire si votre solde est insuffisant ?',
            'If your available balance cannot cover this price, use the top-up option shown by the insufficient-balance message. Return to Activate after the recharge. This guide never requests a number for you.',
            'Si votre solde disponible ne couvre pas ce prix, utilisez l’option de recharge proposée dans le message de solde insuffisant. Revenez dans Activer après la recharge. Ce guide ne demande jamais un numéro à votre place.'),
        ];
      case 'active':
        return const [
          _GuideStep('ACTIVE NUMBERS LIST', 'LISTE DES NUMÉROS ACTIFS',
            'Your ongoing activations', 'Vos activations en cours',
            'This page brings together your active VT-NUM and T-NUM operations. The origin label tells you which system created each operation.',
            'Cette page rassemble vos opérations VT-NUM et T-NUM en cours. Le libellé d’origine indique le système utilisé pour chaque opération.'),
          _GuideStep('NUMBER AND STATUS', 'NUMÉRO ET STATUT',
            'Check each operation', 'Vérifiez chaque opération',
            'Each item shows information such as service, country, number and status. Open an item to see its detailed tracking screen.',
            'Chaque élément affiche notamment le service, le pays, le numéro et le statut. Ouvrez un élément pour consulter son suivi détaillé.'),
          _GuideStep('SMS / VERIFICATION CODE', 'SMS / CODE DE VÉRIFICATION',
            'Copy the SMS code', 'Copiez le code SMS',
            'When the SMS arrives, open the operation details. Use the copy control and paste the code into the app or website that requested it.',
            'À l’arrivée du SMS, ouvrez les détails de l’opération. Utilisez le bouton de copie et collez le code dans l’application ou le site qui l’a demandé.',
            allowTargetInteraction: false),
          _GuideStep('AVAILABLE ACTIONS', 'ACTIONS DISPONIBLES',
            'Follow the operation', 'Suivez l’opération',
            'Use the refresh or action buttons shown for an operation when needed. Read the confirmation before completing or cancelling anything.',
            'Utilisez les boutons d’actualisation ou d’action disponibles si nécessaire. Lisez la confirmation avant de terminer ou d’annuler une opération.',
            allowTargetInteraction: false),
        ];
      case 'history':
        return const [
          _GuideStep('HISTORY LIST', 'LISTE DE L’HISTORIQUE',
            'Your previous activations', 'Vos anciennes activations',
            'History combines your VT-NUM and T-NUM activation records. The newest operations appear first.',
            'L’historique rassemble vos activations VT-NUM et T-NUM. Les opérations les plus récentes apparaissent en premier.'),
          _GuideStep('ORIGIN AND STATUS', 'ORIGINE ET STATUT',
            'Understand each record', 'Comprenez chaque opération',
            'The origin label identifies VT-NUM or T-NUM. Each record also shows details such as service, country, date, price and status.',
            'Le libellé d’origine indique VT-NUM ou T-NUM. Chaque opération affiche aussi le service, le pays, la date, le prix et le statut.'),
          _GuideStep('OPEN A HISTORY ITEM', 'OUVRIR UNE OPÉRATION',
            'See the details', 'Consultez les détails',
            'Tap any record to open its details and review the number, available SMS information and operation status.',
            'Touchez une opération pour ouvrir ses détails et revoir le numéro, les informations SMS disponibles et son statut.'),
          _GuideStep('HISTORY LIST', 'LISTE DE L’HISTORIQUE',
            'Refresh the list', 'Actualisez la liste',
            'Pull the list down to refresh your records when you want to see the latest information.',
            'Faites glisser la liste vers le bas pour actualiser les opérations et voir les dernières informations.'),
        ];
      case 'topup':
        return const [
          _GuideStep('PAYMENT PROVIDER', 'PRESTATAIRE DE PAIEMENT',
            'Choose a payment provider', 'Choisissez un prestataire',
            'Choose one of the payment providers shown in the list. Available options may depend on your account and location.',
            'Choisissez l’un des prestataires proposés. Les options disponibles peuvent dépendre de votre compte et de votre pays.'),
          _GuideStep('AMOUNT (USD)', 'MONTANT (USD)',
            'Enter the recharge amount', 'Saisissez le montant à recharger',
            'Enter the amount you want to add and respect the minimum and maximum shown. Review the estimated fees and credited amount.',
            'Saisissez le montant souhaité et respectez le minimum et le maximum indiqués. Vérifiez les frais estimés et le montant crédité.'),
          _GuideStep('MOBILE NUMBER', 'NUMÉRO MOBILE',
            'Enter the payment phone number', 'Saisissez le numéro de paiement',
            'Enter the phone number that will approve the payment. In Cameroon, follow the helper text under the field. With Fapshi, also select MTN Mobile Money or Orange Money.',
            'Saisissez le numéro qui servira à valider le paiement. Au Cameroun, suivez l’aide sous le champ. Avec Fapshi, choisissez aussi MTN Mobile Money ou Orange Money.'),
          _GuideStep('RECHARGE SUMMARY', 'RÉCAPITULATIF DE LA RECHARGE',
            'Review the summary', 'Vérifiez le récapitulatif',
            'Check the amount to credit, fees, exchange rate and total requested. If something looks wrong, close the form and correct your entries before paying.',
            'Vérifiez le montant à créditer, les frais, le taux de change et le total demandé. En cas d’erreur, fermez le formulaire et corrigez vos saisies avant de payer.'),
          _GuideStep('REQUEST PAYMENT', 'DEMANDER LE PAIEMENT',
            'Approve the payment', 'Validez le paiement',
            'When you are ready, tap Request payment once, then approve the prompt on your phone. Keep the screen open while the payment is checked. Your wallet is credited only after success is confirmed.',
            'Lorsque vous êtes prêt, touchez Demander le paiement une seule fois, puis validez la demande sur votre téléphone. Gardez l’écran ouvert pendant la vérification. Votre portefeuille est crédité uniquement après confirmation de la réussite.',
            allowTargetInteraction: false),
        ];
      default:
        return const [];
    }
  }
}

class _GuideStep {
  const _GuideStep(
    this.targetEn, this.targetFr, this.titleEn, this.titleFr,
    this.bodyEn, this.bodyFr, {
    this.allowTargetInteraction = true,
  });
  final bool allowTargetInteraction;
  final String targetEn;
  final String targetFr;
  final String titleEn;
  final String titleFr;
  final String bodyEn;
  final String bodyFr;
}

enum _GuideResult { finished, skipAll }

Future<_GuideResult?> _showSpotlightGuide(
  BuildContext context, {
  required String section,
  required bool french,
  required List<_GuideStep> steps,
  ValueChanged<String>? onStepChanged,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final completion = Completer<_GuideResult?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _SpotlightGuideOverlay(
      section: section,
      french: french,
      steps: steps,
      onStepChanged: onStepChanged,
      onComplete: (result) {
        if (!completion.isCompleted) completion.complete(result);
        entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return completion.future;
}

class _SpotlightGuideOverlay extends StatefulWidget {
  const _SpotlightGuideOverlay({
    required this.section,
    required this.french,
    required this.steps,
    required this.onComplete,
    this.onStepChanged,
  });

  final String section;
  final bool french;
  final List<_GuideStep> steps;
  final ValueChanged<_GuideResult> onComplete;
  final ValueChanged<String>? onStepChanged;

  @override
  State<_SpotlightGuideOverlay> createState() => _SpotlightGuideOverlayState();
}

class _SpotlightGuideOverlayState extends State<_SpotlightGuideOverlay> {
  int _index = 0;
  Rect? _targetRect;
  bool _targetReady = false;
  int _focusGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrentStep());
  }

  Future<void> _focusCurrentStep() async {
    if (!mounted || widget.steps.isEmpty) return;

    final generation = ++_focusGeneration;
    final step = widget.steps[_index];
    widget.onStepChanged?.call(step.targetEn);
    if (widget.onStepChanged != null) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final key = FirstTimeAppGuide.anchorKey(widget.section, step.targetEn);
    BuildContext? targetContext;
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted || generation != _focusGeneration) return;
      targetContext = key.currentContext;
      if (targetContext != null && targetContext.mounted) break;

      if (attempt == 2) {
        _revealCallbacks[widget.section]?.call();
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    if (targetContext != null && targetContext.mounted) {
      try {
        await Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeInOutCubic,
          alignment: 0.32,
        );
      } catch (_) {
        // A target may not be inside a scrollable; its current position is valid.
      }
    }

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _focusGeneration) return;
    if (!mounted) return;

    Rect? rect;
    final currentContext = key.currentContext;
    if (currentContext != null) {
      final targetObject = currentContext.findRenderObject();
      final overlayObject = Overlay.of(
        context,
        rootOverlay: true,
      ).context.findRenderObject();

      if (targetObject is RenderBox &&
          targetObject.hasSize &&
          overlayObject is RenderBox) {
        final topLeft = targetObject.localToGlobal(
          Offset.zero,
          ancestor: overlayObject,
        );
        final screenRect = Offset.zero & MediaQuery.sizeOf(context);
        final measuredRect = topLeft & targetObject.size;
        if (measuredRect.overlaps(screenRect)) {
          rect = measuredRect.intersect(screenRect);
        }
      }
    }

    setState(() {
      _targetRect = rect;
      _targetReady = true;
    });
  }

  void _next() {
    if (_index >= widget.steps.length - 1) {
      widget.onComplete(_GuideResult.finished);
      return;
    }
    _focusGeneration++;
    setState(() {
      _index++;
      _targetReady = false;
      _targetRect = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrentStep());
  }

  void _back() {
    if (_index == 0) return;
    _focusGeneration++;
    setState(() {
      _index--;
      _targetReady = false;
      _targetRect = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrentStep());
  }

  String get _sectionTitle {
    final fr = widget.french;
    return switch (widget.section) {
      'auth' => fr ? 'INSCRIPTION ET CONNEXION' : 'SIGN UP AND LOGIN',
      'home' => fr ? 'ACCUEIL' : 'HOME',
      'activate' => fr ? 'ACTIVATION' : 'ACTIVATION',
      'active' => fr ? 'ACTIVATIONS EN COURS' : 'ACTIVE ACTIVATIONS',
      'history' => fr ? 'HISTORIQUE' : 'HISTORY',
      'topup' => fr ? 'RECHARGE' : 'TOP-UP',
      _ => 'GUIDE',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onComplete(_GuideResult.finished);
      });
      return const SizedBox.shrink();
    }

    final size = MediaQuery.sizeOf(context);
    final step = widget.steps[_index];
    final target = widget.french ? step.targetFr : step.targetEn;
    final title = widget.french ? step.titleFr : step.titleEn;
    final body = widget.french ? step.bodyFr : step.bodyEn;
    final progress = (_index + 1) / widget.steps.length;
    final count = (_index + 1).toString() + '/' + widget.steps.length.toString();
    final bubbleWidth = size.width < 480 ? size.width - 28 : 440.0;
    final bubbleHeight = (size.height - 24).clamp(120.0, 390.0).toDouble();
    final targetRect = _targetReady ? _targetRect : null;

    double bubbleTop;
    if (targetRect == null) {
      bubbleTop = (size.height - bubbleHeight) / 2;
    } else if (targetRect.bottom + bubbleHeight + 18 < size.height) {
      bubbleTop = targetRect.bottom + 18;
    } else {
      bubbleTop = targetRect.top - bubbleHeight - 18;
    }
    final maxBubbleTop = size.height - bubbleHeight - 8.0;
    bubbleTop = bubbleTop.clamp(8.0, maxBubbleTop >= 8.0 ? maxBubbleTop : 8.0).toDouble();

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) widget.onComplete(_GuideResult.skipAll);
      },
      child: _SpotlightHitTestRegion(
      holeRect: _targetReady && step.allowTargetInteraction ? targetRect : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: CustomPaint(
              painter: _SpotlightPainter(targetRect: targetRect?.inflate(7)),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: (size.width - bubbleWidth) / 2,
            top: bubbleTop,
            width: bubbleWidth,
            child: Material(
              color: const Color(0xFF101A31),
              elevation: 24,
              shadowColor: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: BoxConstraints(maxHeight: bubbleHeight),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: const Color(0xFF7199FF).withValues(alpha: 0.55),
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF4776FF), Color(0xFF8B5CF6)],
                              ),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Icon(
                              Icons.lightbulb_outline_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.french ? 'GUIDE PAS À PAS' : 'FIRST-TIME APP GUIDE',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _sectionTitle,
                                  style: const TextStyle(
                                    color: Color(0xFF9FB5E6),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.7,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => widget.onComplete(_GuideResult.skipAll),
                            child: Text(widget.french ? 'Ignorer' : 'Skip'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF6E8BFF)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(Icons.touch_app_rounded, color: Color(0xFF8FB6FF), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              target,
                              style: const TextStyle(
                                color: Color(0xFF8FB6FF),
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.45,
                              ),
                            ),
                          ),
                          Text(count, style: const TextStyle(color: Color(0xFF8393B3), fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 13),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: Column(
                          key: ValueKey<int>(_index),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 21,
                                height: 1.2,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 10),
                            TweenAnimationBuilder<double>(
                              key: ValueKey<String>('spotlight-typed-$_index'),
                              tween: Tween(begin: 0, end: 1),
                              duration: Duration(milliseconds: (body.length * 12).clamp(700, 1500).toInt()),
                              curve: Curves.easeOut,
                              builder: (context, value, _) {
                                final visible = (body.length * value).round().clamp(0, body.length).toInt();
                                return Text(
                                  body.substring(0, visible),
                                  style: const TextStyle(
                                    color: Color(0xFFC1CBE0),
                                    fontSize: 13,
                                    height: 1.6,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          if (_index > 0)
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _back,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                ),
                                child: Text(widget.french ? 'Précédent' : 'Back'),
                              ),
                            )
                          else
                            const Spacer(),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: FilledButton(
                              onPressed: _next,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF4776FF),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 13),
                              ),
                              child: Text(
                                _index == widget.steps.length - 1
                                    ? (widget.french ? 'Terminer' : 'Finish')
                                    : (widget.french ? 'Suivant' : 'Next'),
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.french
                            ? 'Le guide ne réalise aucun achat ni paiement. Vous pouvez l’ignorer.'
                            : 'The guide never makes a purchase or payment. You can skip it.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF7788A9), fontSize: 10, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({required this.targetRect});
  final Rect? targetRect;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (targetRect != null) {
      path.addRRect(RRect.fromRectAndRadius(targetRect!, const Radius.circular(16)));
    }
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.78));
    if (targetRect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(targetRect!, const Radius.circular(16)),
        Paint()
          ..color = const Color(0xFF80A7FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      oldDelegate.targetRect != targetRect;
}

class _SpotlightHitTestRegion extends SingleChildRenderObjectWidget {
  const _SpotlightHitTestRegion({required this.holeRect, required super.child});
  final Rect? holeRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSpotlightHitTestRegion(holeRect);

  @override
  void updateRenderObject(BuildContext context, covariant _RenderSpotlightHitTestRegion renderObject) {
    renderObject.holeRect = holeRect;
  }
}

class _RenderSpotlightHitTestRegion extends RenderProxyBox {
  _RenderSpotlightHitTestRegion(this.holeRect);
  Rect? holeRect;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (holeRect?.contains(position) == true) return false;
    return super.hitTest(result, position: position);
  }
}
