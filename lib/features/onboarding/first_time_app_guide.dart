import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FirstTimeAppGuide {
  FirstTimeAppGuide._();

  static const pendingPreferenceKey =
      'online_sim_first_time_guide_pending';
  static const _sections = <String>[
    'auth', 'home', 'activate', 'active', 'history', 'topup',
  ];
  static final Set<String> _showing = <String>{};

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

  static Future<void> showIfNeeded(
    BuildContext context,
    String section,
  ) async {
    if (!_sections.contains(section) || _showing.contains(section)) return;
    _showing.add(section);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!context.mounted ||
          prefs.getBool(pendingPreferenceKey) != true ||
          prefs.getBool(_doneKey(section)) == true) {
        return;
      }

      final french =
          Localizations.localeOf(context).languageCode.toLowerCase() == 'fr';
      final result = await showDialog<_GuideResult>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.78),
        builder: (_) => _GuideDialog(
          section: section,
          french: french,
          steps: _steps(section),
        ),
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
            'Tap Create account once. Follow the email verification instructions, then return and choose Log in. Existing users can switch to Log in at the bottom.',
            'Touchez Créer un compte une seule fois. Suivez les instructions de vérification reçues par e-mail, puis revenez choisir Se connecter. Les utilisateurs déjà inscrits peuvent choisir Se connecter en bas.'),
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
            'Tap Get number and read the confirmation carefully. Confirm only if the service, country and price are correct. Do not tap repeatedly while the request is processing.',
            'Touchez Obtenir un numéro et lisez attentivement la confirmation. Confirmez uniquement si le service, le pays et le prix sont corrects. Ne touchez pas plusieurs fois pendant le traitement.'),
          _GuideStep('T-NUM: COUNTRY AND SERVICE', 'T-NUM : PAYS ET SERVICE',
            'Choose with T-NUM', 'Choisissez avec T-NUM',
            'Switch to Server 2. Choose the country, then select the service from the available list. Use the search field to find a service faster.',
            'Passez à Server 2. Choisissez le pays, puis le service dans la liste proposée. Utilisez la recherche pour trouver le service plus rapidement.'),
          _GuideStep('T-NUM: PRICE AND PURCHASE', 'T-NUM : PRIX ET ACHAT',
            'Review before buying', 'Vérifiez avant l’achat',
            'Check the displayed customer price and tap the purchase button. Confirm the price in the confirmation window to request the number.',
            'Vérifiez le prix client affiché et touchez le bouton d’achat. Confirmez le prix dans la fenêtre de confirmation pour demander le numéro.'),
          _GuideStep('NUMBER AND SMS', 'NUMÉRO ET SMS',
            'Receive your verification code', 'Recevez votre code de vérification',
            'When the number appears, enter it in the app or website you are verifying. Keep the activation open and wait for the SMS. Copy the code when it arrives.',
            'Quand le numéro apparaît, saisissez-le dans l’application ou le site à vérifier. Gardez l’activation ouverte et attendez le SMS. Copiez le code dès son arrivée.'),
          _GuideStep('INSUFFICIENT BALANCE', 'SOLDE INSUFFISANT',
            'What if your balance is too low?', 'Que faire si votre solde est insuffisant ?',
            'Use the Top up wallet action in the insufficient-balance message. Add funds, return to Activate and try again. This guide never buys a number for you.',
            'Utilisez le bouton Recharger dans le message de solde insuffisant. Ajoutez des fonds, revenez dans Activer et réessayez. Ce guide n’achète jamais un numéro à votre place.'),
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
            'À l’arrivée du SMS, ouvrez les détails de l’opération. Utilisez le bouton de copie et collez le code dans l’application ou le site qui l’a demandé.'),
          _GuideStep('AVAILABLE ACTIONS', 'ACTIONS DISPONIBLES',
            'Follow the operation', 'Suivez l’opération',
            'Use the refresh or action buttons shown for an operation when needed. Read the confirmation before completing or cancelling anything.',
            'Utilisez les boutons d’actualisation ou d’action disponibles si nécessaire. Lisez la confirmation avant de terminer ou d’annuler une opération.'),
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
          _GuideStep('PULL TO REFRESH', 'TIRER POUR ACTUALISER',
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
            'Tap Request payment once, then approve the prompt on your phone. Keep the screen open while the payment is checked. Your wallet is credited only after success is confirmed.',
            'Touchez Demander le paiement une seule fois, puis validez la demande sur votre téléphone. Gardez l’écran ouvert pendant la vérification. Votre portefeuille est crédité uniquement après confirmation de la réussite.'),
        ];
      default:
        return const [];
    }
  }
}

class _GuideStep {
  const _GuideStep(
    this.targetEn, this.targetFr, this.titleEn, this.titleFr,
    this.bodyEn, this.bodyFr,
  );
  final String targetEn;
  final String targetFr;
  final String titleEn;
  final String titleFr;
  final String bodyEn;
  final String bodyFr;
}

enum _GuideResult { finished, skipAll }

class _GuideDialog extends StatefulWidget {
  const _GuideDialog({
    required this.section,
    required this.french,
    required this.steps,
  });
  final String section;
  final bool french;
  final List<_GuideStep> steps;

  @override
  State<_GuideDialog> createState() => _GuideDialogState();
}

class _GuideDialogState extends State<_GuideDialog> {
  int _index = 0;

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

  void _next() {
    if (_index < widget.steps.length - 1) {
      setState(() => _index++);
    } else {
      Navigator.of(context).pop(_GuideResult.finished);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(_GuideResult.finished);
      });
      return const SizedBox.shrink();
    }

    final step = widget.steps[_index];
    final target = widget.french ? step.targetFr : step.targetEn;
    final title = widget.french ? step.titleFr : step.titleEn;
    final body = widget.french ? step.bodyFr : step.bodyEn;
    final progress = (_index + 1) / widget.steps.length;
    final count = (_index + 1).toString() + '/' + widget.steps.length.toString();

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: const Color(0xFF101A31),
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(
            color: const Color(0xFF7199FF).withValues(alpha: 0.38),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 570),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF4776FF), Color(0xFF8B5CF6)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.lightbulb_outline_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.french ? 'GUIDE PAS À PAS' : 'FIRST-TIME APP GUIDE',
                            style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w900,
                              fontSize: 13, letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _sectionTitle,
                            style: const TextStyle(
                              color: Color(0xFF9FB5E6), fontSize: 10,
                              fontWeight: FontWeight.w800, letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(_GuideResult.skipAll),
                      child: Text(widget.french ? 'Ignorer' : 'Skip'),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: LinearProgressIndicator(
                    value: progress, minHeight: 5,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF6E8BFF)),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.92, end: 1.06),
                      duration: const Duration(milliseconds: 750),
                      curve: Curves.easeInOut,
                      builder: (context, value, child) =>
                          Transform.scale(scale: value, child: child),
                      child: const Icon(Icons.touch_app_rounded, color: Color(0xFF8FB6FF), size: 22),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        target,
                        style: const TextStyle(
                          color: Color(0xFF8FB6FF), fontSize: 10,
                          fontWeight: FontWeight.w900, letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Text(count, style: const TextStyle(color: Color(0xFF8393B3), fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 14),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: const Offset(0.035, 0), end: Offset.zero).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: ValueKey<int>(_index),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, height: 1.2, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 12),
                      TweenAnimationBuilder<double>(
                        key: ValueKey<String>('typed-' + _index.toString()),
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(milliseconds: (body.length * 14).clamp(850, 1700).toInt()),
                        curve: Curves.easeOut,
                        builder: (context, value, _) {
                          final visible = (body.length * value).round().clamp(0, body.length);
                          return Text(
                            body.substring(0, visible),
                            style: const TextStyle(color: Color(0xFFC1CBE0), fontSize: 14, height: 1.65),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    if (_index > 0)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() => _index--),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
                          padding: const EdgeInsets.symmetric(vertical: 14),
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
                const SizedBox(height: 7),
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
    );
  }
}
