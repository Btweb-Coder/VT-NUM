import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/localization/app_localizations.dart';

/// Décode les entités HTML, y compris lorsqu'elles ont été encodées plusieurs fois.
String _decodeSmsHtml(String input) {
  var value = input;
  final entity = RegExp(r'&(#(?:x[0-9a-fA-F]+|[0-9]+)|amp|lt|gt|quot|apos|nbsp);', caseSensitive: false);
  for (var pass = 0; pass < 5; pass++) {
    final decoded = value.replaceAllMapped(entity, (match) {
      final token = match.group(1)!;
      final lower = token.toLowerCase();
      if (lower == 'amp') return '&';
      if (lower == 'lt') return '<';
      if (lower == 'gt') return '>';
      if (lower == 'quot') return '"';
      if (lower == 'apos') return "'";
      if (lower == 'nbsp') return '\u00A0';
      try {
        final number = lower.startsWith('#x')
            ? int.parse(lower.substring(2), radix: 16)
            : int.parse(lower.substring(1));
        if (number == 10 || number == 13) return '\n';
        if (number < 0 || number > 0x10FFFF || (number >= 0xD800 && number <= 0xDFFF)) return match.group(0)!;
        return String.fromCharCode(number);
      } catch (_) {
        return match.group(0)!;
      }
    });
    if (decoded == value) break;
    value = decoded;
  }
  return value.replaceAll('\\r\\n', '\n').replaceAll('\\n', '\n').replaceAll('\\r', '\n');
}

String _smsVerificationCode(Map<String, dynamic> message, String body) {
  final explicit = _decodeSmsHtml('${message['sms_code'] ?? ''}').trim();
  if (explicit.isNotEmpty) return explicit;
  // Repli prudent : seulement les formats courants de code à 6 chiffres.
  final match = RegExp(r'(?<![A-Za-z0-9])([0-9]{3,4}[- ][0-9]{3,4})(?![A-Za-z0-9])').firstMatch(body);
  return match?.group(1)?.replaceAll(' ', '-') ?? '';
}

class RentalsPage extends StatefulWidget {
  const RentalsPage({super.key});

  @override
  State<RentalsPage> createState() => _RentalsPageState();
}

class _RentalsPageState extends State<RentalsPage> with WidgetsBindingObserver {
  final SupabaseClient _client = Supabase.instance.client;

  Map<String, dynamic>? _catalog;
  String? _error;
  bool _catalogLoading = false;
  bool _purchasePending = false;
  bool _rentalActionPending = false;
  String? _country;
  int? _hours;
  String _catalogMode = 'country';
  String _serviceSearch = '';
  String _countrySearch = '';
  String _rentalSearch = '';
  String _rentalStatusFilter = 'TOUS';

  int _catalogRequestVersion = 0;
  String? _pendingBuyKey;
  String? _pendingBuyFingerprint;
  final Map<String, String> _operationKeys = {};

  bool get _busy => _catalogLoading || _purchasePending || _rentalActionPending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCatalog();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadCatalog();
  }

  String _key() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

  String _operationKey(String scope) => _operationKeys.putIfAbsent(scope, _key);

  // Texte affichable côté client : ne révèle jamais le nom du fournisseur.
  String _publicMessage(Object value) {
    return value.toString()
        .replaceAll(
  RegExp(r'proxnum-rentals', caseSensitive: false),
  'serveur',
)
.replaceAll(
  RegExp(r'proxnum', caseSensitive: false),
  'serveur',
);
  }

Future<void> _loadCatalog() async {
  if (!mounted) return;
  final strings = context.strings;

  final version = ++_catalogRequestVersion;

  final requestBody = <String, dynamic>{
    'action': 'catalog',
    if (_country != null) 'country': _country,
    if (_hours != null) 'hours': _hours,
  };

  debugPrint('\n========== ONLINE SIM : CATALOGUE LOCATIONS ==========');
  debugPrint('[FLUTTER] Paramètres envoyés : $requestBody');
  debugPrint('[FLUTTER] Mode catalogue : $_catalogMode');
  debugPrint('[FLUTTER] Pays sélectionné : $_country');
  debugPrint('[FLUTTER] Durée sélectionnée : $_hours');

  setState(() {
    _catalogLoading = true;
    _error = null;
  });

  try {
    final response = await _client.functions.invoke(
      'proxnum-rentals',
      body: requestBody,
    );

    debugPrint('[FLUTTER] HTTP status : ${response.status}');
    debugPrint('[FLUTTER] Réponse complète : ${response.data}');

    if (response.status < 200 || response.status >= 300) {
      throw Exception(strings.text('rentals.catalog_http_error', variables: {'status': response.status}));
    }

    if (response.data is! Map) {
      throw Exception(strings.text('rentals.catalog_response_invalid'));
    }

    final data = Map<String, dynamic>.from(response.data as Map);

    if (data['catalog'] is! Map) {
      debugPrint('[FLUTTER] ERREUR : clé catalog absente ou invalide.');
      throw Exception(strings.text('rentals.catalog_missing'));
    }

    final catalog = Map<String, dynamic>.from(data['catalog'] as Map);

    final countries = (catalog['countries'] as List?) ?? [];
    final durations = (catalog['durations'] as List?) ?? [];
    final services = (catalog['services'] as List?) ?? [];

    debugPrint('[FLUTTER] Nombre de pays reçus : ${countries.length}');
    debugPrint('[FLUTTER] Nombre de durées reçues : ${durations.length}');
    debugPrint('[FLUTTER] Nombre de services reçus : ${services.length}');

    debugPrint('[FLUTTER] LISTE COMPLÈTE DES PAYS :');
    for (final country in countries) {
      debugPrint('  - $country');
    }

    debugPrint('[FLUTTER] DURÉES DISPONIBLES : $durations');
    debugPrint('[FLUTTER] Catalogue : pays=${catalog['country']}, heures=${catalog['hours']}');

    if (!mounted || version != _catalogRequestVersion) {
      debugPrint('[FLUTTER] Réponse ignorée : requête devenue obsolète.');
      return;
    }

    setState(() {
      _catalog = catalog;
      _error = null;
    });

    debugPrint('[FLUTTER] Catalogue appliqué à l’écran.');
  } catch (e, stackTrace) {
    debugPrint('[FLUTTER] ERREUR CATALOGUE : $e');
    debugPrint('[FLUTTER] STACK TRACE : $stackTrace');

    if (mounted && version == _catalogRequestVersion) {
      setState(() => _error = _publicMessage(e));
    }
  } finally {
    if (mounted && version == _catalogRequestVersion) {
      setState(() => _catalogLoading = false);
    }

    debugPrint('========== FIN DIAGNOSTIC CATALOGUE ==========\n');
  }
}

  String _syncLabel(Map<String, dynamic> rental) {
    final raw = rental['last_sync_at'];
    if (raw is! String) return context.strings.text('rentals.sync_never_confirmed');

    final last = DateTime.tryParse(raw)?.toLocal();
    if (last == null) return context.strings.text('rentals.sync_unknown');

    final failures = (rental['sync_failures'] as num?)?.toInt() ?? 0;
    if (DateTime.now().difference(last) > const Duration(minutes: 1)) {
      return context.strings.text('rentals.sync_stale', variables: {'date': '$last'});
    }
    if (failures > 0) {
      return context.strings.text('rentals.sync_error', variables: {'count': failures, 'error': '${rental['last_sync_error'] ?? ''}'});
    }
    return context.strings.text('rentals.sync_verified', variables: {'date': '$last'});
  }

  Future<void> _cancel(Map<String, dynamic> rental) async {
    if (_busy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.text('rentals.annul_title')),
        content: Text(
          context.strings.text('rentals.cancel_confirm_body'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.text('rentals.back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.text('rentals.request')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) {
      debugPrint('[RENTAL-CANCEL] Demande annulée par l’utilisateur ou action occupée.');
      return;
    }

    final rentalId = '${rental['id']}';
    final strings = context.strings;
    final key = _operationKey('cancel:$rentalId');
    debugPrint('\n========== RENTAL CANCEL : DÉBUT ==========' );
    debugPrint('[RENTAL-CANCEL] rentalId=$rentalId');
    debugPrint('[RENTAL-CANCEL] endpoint=proxnum-rentals, action=cancel');
    debugPrint('[RENTAL-CANCEL] idempotencyKey réutilisée pour cette location (valeur masquée)');
    setState(() => _rentalActionPending = true);

    try {
      debugPrint('[RENTAL-CANCEL] Envoi de la demande à Supabase Edge Function…');
      final response = await _client.functions.invoke(
        'proxnum-rentals',
        body: {'action': 'cancel', 'rentalId': rentalId, 'idempotencyKey': key},
      );
      debugPrint('[RENTAL-CANCEL] HTTP status=${response.status}');
      debugPrint('[RENTAL-CANCEL] Réponse brute=${response.data}');
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};

      if (response.status < 200 || response.status >= 300) {
        debugPrint('[RENTAL-CANCEL] ÉCHEC HTTP : status=${response.status}, error=${data['error']}');
        throw Exception(
          '${_publicMessage(data['error'] ?? strings.text('rentals.cancel_unconfirmed_generic'))} '
          '(${response.status})',
        );
      }

      final pending =
          response.status == 202 ||
          data['pending'] == true ||
          data['status'] == 'CANCEL_PENDING' ||
          data['status'] == 'CANCEL_REQUESTED';
      debugPrint('[RENTAL-CANCEL] status métier=${data['status']}, pending=$pending');
      debugPrint('[RENTAL-CANCEL] IMPORTANT : réponse reçue ne signifie pas remboursement confirmé.');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              pending
                  ? context.strings.text('rentals.cancel_pending')
                  : context.strings.text('rentals.cancel_received'),
            ),
          ),
        );
      }
      // Keep the key for retries of this same cancellation.
    } catch (e, stackTrace) {
      debugPrint('[RENTAL-CANCEL] EXCEPTION : $e');
      debugPrint('[RENTAL-CANCEL] STACK TRACE : $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('rentals.cancel_unconfirmed', variables: {'message': _publicMessage(e)}))),
        );
      }
    } finally {
      if (mounted) setState(() => _rentalActionPending = false);
      debugPrint('========== RENTAL CANCEL : FIN ==========\n');
    }
  }

  Future<void> _extend(Map<String, dynamic> rental) async {
    if (_busy) return;
    final strings = context.strings;
    final rentalId = '${rental['id']}';
    setState(() => _rentalActionPending = true);

    try {
      final response = await _client.functions.invoke(
        'proxnum-rentals',
        body: {'action': 'extend-options', 'rentalId': rentalId},
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception(
          strings.text('rentals.renew_options_http_error', variables: {'status': response.status}),
        );
      }
      if (response.data is! Map) {
        throw Exception(strings.text('rentals.renew_options_response_invalid'));
      }

      final rawOptions = Map<String, dynamic>.from(
        response.data as Map,
      )['options'];
      if (rawOptions is! List) {
        throw Exception(strings.text('rentals.renew_options_list_invalid'));
      }
      final options = rawOptions
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (!mounted) return;
      if (options.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.strings.text('rentals.no_durations')),
          ),
        );
        return;
      }

      final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: options
                .map(
                  (option) => ListTile(
                    title: Text('${option['label']}'),
                    subtitle: Text(
                      context.strings.text('rentals.client_price', variables: {'amount': option['customerPrice']}),
                    ),
                    onTap: () => Navigator.pop(context, option),
                  ),
                )
                .toList(),
          ),
        ),
      );
      if (selected == null || !mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.strings.text('rentals.confirm_renewal')),
          content: Text(
            context.strings.text('rentals.renew_confirm_body', variables: {'label': selected['label'], 'amount': selected['customerPrice']}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.text('rentals.back')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.text('rentals.renew')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final expiration = '${rental['expires_at'] ?? 'unknown'}';
      final hours = selected['hours'];
      final key = _operationKey('extend:$rentalId:$expiration:$hours');

      final result = await _client.functions.invoke(
        'proxnum-rentals',
        body: {
          'action': 'extend',
          'rentalId': rentalId,
          'idempotencyKey': key,
          'hours': hours,
          'expectedCustomerPrice': selected['customerPrice'],
        },
      );
      final data = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};

      if (result.status < 200 || result.status >= 300) {
        throw Exception(
          '${_publicMessage(data['error'] ?? strings.text('rentals.renew_unconfirmed_generic'))} '
          '(${result.status})',
        );
      }

      final pending =
          result.status == 202 ||
          data['pending'] == true ||
          data['status'] == 'RECONCILIATION_REQUIRED' ||
          data['status'] == 'RENEWAL_REQUESTED';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              pending
                  ? strings.text('rentals.renew_reconciling')
                  : strings.text('rentals.renew_server_confirmation'),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('rentals.renew_unconfirmed', variables: {'message': _publicMessage(e)}))),
        );
      }
    } finally {
      if (mounted) setState(() => _rentalActionPending = false);
    }
  }

  Future<void> _buy(Map<String, dynamic> offer) async {
    if (_busy || _catalog == null) return;

    final strings = context.strings;

    final catalog = _catalog!;
    final country = _country ?? '${catalog['country']}';
    final hours = _hours ?? (catalog['hours'] as num).toInt();
    final serviceCode = '${offer['code']}';
    final displayedPrice = offer['customerPrice'];
    final fingerprint = '$country|$serviceCode|$hours|$displayedPrice';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.text('rentals.confirm_rental')),
        content: Text(
          context.strings.text('rentals.purchase_confirm_body', variables: {'name': offer['name'], 'amount': displayedPrice, 'hours': hours}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.text('rentals.back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.text('rentals.continue')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) {
      debugPrint('[RENTAL-BUY] Achat annulé par l’utilisateur ou action occupée.');
      return;
    }

    debugPrint('\n========== RENTAL BUY : DÉBUT ==========' );
    debugPrint('[RENTAL-BUY] Offre=${offer['name']}');
    debugPrint('[RENTAL-BUY] Pays=$country, service=$serviceCode, durée=${hours}h');
    debugPrint('[RENTAL-BUY] Prix affiché client=$displayedPrice USD');
    debugPrint('[RENTAL-BUY] fingerprint=$fingerprint');

    if (_pendingBuyFingerprint != fingerprint || _pendingBuyKey == null) {
      _pendingBuyFingerprint = fingerprint;
      _pendingBuyKey = _key();
    }
    final idempotencyKey = _pendingBuyKey!;
    debugPrint('[RENTAL-BUY] idempotencyKey présente (valeur masquée), clé conservée si résultat incertain.');

    setState(() => _purchasePending = true);

    try {
      debugPrint('[RENTAL-BUY] Envoi de la demande à Supabase Edge Function…');
      debugPrint('[RENTAL-BUY] payload={action: buy, service: $serviceCode, country: $country, hours: $hours, expectedCustomerPrice: $displayedPrice}');
      final response = await _client.functions.invoke(
        'proxnum-rentals',
        body: {
          'action': 'buy',
          'idempotencyKey': idempotencyKey,
          'service': serviceCode,
          'country': country,
          'hours': hours,
          'expectedCustomerPrice': displayedPrice,
        },
      );
      debugPrint('[RENTAL-BUY] HTTP status=${response.status}');
      debugPrint('[RENTAL-BUY] Réponse brute=${response.data}');
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};

      final pending =
          response.status == 202 ||
          data['pending'] == true ||
          data['status'] == 'RECONCILIATION_REQUIRED';
      debugPrint('[RENTAL-BUY] success=${data['success']}, status métier=${data['status']}, pending=$pending');

      if (pending) {
        debugPrint('[RENTAL-BUY] RÉSULTAT EN ATTENTE : conservation de la clé, ne pas relancer un nouvel achat.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.strings.text('rentals.purchase_reconciling'),
              ),
            ),
          );
        }
        // Keep the key because the result is unresolved.
        return;
      }

      if (response.status < 200 ||
          response.status >= 300 ||
          data['success'] != true) {
        debugPrint('[RENTAL-BUY] NON CONFIRMÉ : status=${response.status}, error=${data['error']}');
        throw Exception(
          '${_publicMessage(data['error'] ?? strings.text('rentals.purchase_unconfirmed_generic'))} (${response.status})',
        );
      }

      debugPrint('[RENTAL-BUY] ACHAT CONFIRMÉ PAR LE SERVEUR.');
      _pendingBuyKey = null;
      _pendingBuyFingerprint = null;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.text('rentals.server_confirmed'))),
        );
      }
      await _loadCatalog();
    } catch (e, stackTrace) {
      debugPrint('[RENTAL-BUY] EXCEPTION : $e');
      debugPrint('[RENTAL-BUY] STACK TRACE : $stackTrace');
      // Preserve the key on errors: the server may have processed the request.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.strings.text('rentals.purchase_unconfirmed', variables: {'error': e.toString()}),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _purchasePending = false);
      debugPrint('========== RENTAL BUY : FIN ==========\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.cardColor;
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);

    final countries =
        (_catalog?['countries'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final durations =
        (_catalog?['durations'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final services =
        (_catalog?['services'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];

    final catalogCountry = _catalog?['country']?.toString();

    final selectedCountry = countries.any((item) => '${item['id']}' == _country)
        ? _country
        : countries.any((item) => '${item['id']}' == catalogCountry)
        ? catalogCountry
        : null;

    final availableHours = durations
        .map((item) => (item['hours'] as num?)?.toInt())
        .whereType<int>()
        .toSet();

    final catalogHours = (_catalog?['hours'] as num?)?.toInt();

    final selectedHours = _hours != null && availableHours.contains(_hours)
        ? _hours
        : (catalogHours != null && availableHours.contains(catalogHours)
              ? catalogHours
              : null);

    final visibleCountries = _countrySearch.isEmpty
        ? countries
        : countries.where((item) {
            final name = '${item['name'] ?? ''}'.toLowerCase();
            final code = '${item['id'] ?? ''}'.toLowerCase();
            return name.contains(_countrySearch) || code.contains(_countrySearch);
          }).toList();

    final visibleServices = _catalogMode == 'app' && _serviceSearch.isNotEmpty
        ? services.where((item) {
            final service = Map<String, dynamic>.from(item);
            final name = '${service['name'] ?? ''}'.toLowerCase();
            final code = '${service['code'] ?? ''}'.toLowerCase();
            return name.contains(_serviceSearch) ||
                code.contains(_serviceSearch);
          }).toList()
        : services;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.strings.text('rentals.title'),
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: FilledButton.icon(
              onPressed: _showMyRentals,
              icon: const Icon(Icons.inventory_2_rounded, size: 20),
              label: Text(context.strings.text('rentals.my_rentals'), style: TextStyle(fontWeight: FontWeight.w800)),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                minimumSize: const Size(0, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          IconButton(
            onPressed: _busy ? null : _loadCatalog,
            tooltip: context.strings.text('rentals.refresh_catalog'),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadCatalog,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 850;
            final horizontalPadding = constraints.maxWidth >= 1100
                ? 32.0
                : constraints.maxWidth >= 600
                ? 24.0
                : 16.0;

            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // En-tête du catalogue
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        primary.withValues(alpha: 0.18),
                        primary.withValues(alpha: 0.045),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: primary.withValues(alpha: 0.16)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.calendar_month_rounded,
                          color: primary,
                          size: 27,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        context.strings.text('rentals.hero_title'),
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.strings.text('rentals.choose_rental_help'),
                        style: TextStyle(
                          color: muted,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _RentalBadge(
                            icon: Icons.public_rounded,
                            label: context.strings.text('rentals.multiple_countries'),
                            color: primary,
                          ),
                          _RentalBadge(
                            icon: Icons.sms_outlined,
                            label: context.strings.text('rentals.sms_during_rental'),
                            color: Colors.teal,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Titre de section
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.strings.text('rentals.find_rental'),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.strings.text('rentals.server_offers'),
                            style: TextStyle(color: muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if (_catalog != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          context.strings.text('rentals.offers_count', variables: {'count': services.length}),
                          style: TextStyle(
                            color: primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 14),

                // Mode de navigation du catalogue
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.public_rounded, size: 18),
                      label: Text(context.strings.text('rentals.by_country')),
                      selected: _catalogMode == 'country',
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                              _catalogMode = 'country';
                              _serviceSearch = '';
                            }),
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.apps_rounded, size: 18),
                      label: Text(context.strings.text('rentals.by_app')),
                      selected: _catalogMode == 'app',
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                              _catalogMode = 'app';
                              _serviceSearch = '';
                            }),
                    ),
                  ],
                ),
                if (_catalogMode == 'app') ...[
                  Text(
                    context.strings.text('rentals.apps_for_selection'),
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    onChanged: (value) => setState(
                      () => _serviceSearch = value.trim().toLowerCase(),
                    ),
                    decoration: InputDecoration(
                      labelText: context.strings.text('rentals.search_app'),
                      hintText: context.strings.text('rentals.search_app_hint'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _serviceSearch.isEmpty
                          ? null
                          : IconButton(
                              tooltip: context.strings.text('rentals.clear_search'),
                              onPressed: () =>
                                  setState(() => _serviceSearch = ''),
                              icon: const Icon(Icons.close_rounded),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),

                // Filtres plus compacts
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.tune_rounded, size: 19, color: primary),
                          const SizedBox(width: 8),
                          Text(
                            context.strings.text('rentals.customize_offer'),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_catalogMode == 'country') ...[
                        TextField(
                          onChanged: (value) => setState(() => _countrySearch = value.trim().toLowerCase()),
                          decoration: InputDecoration(
                            labelText: context.strings.text('rentals.search_country'),
                            hintText: context.strings.text('rentals.country_hint'),
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _countrySearch.isEmpty ? null : IconButton(
                              tooltip: context.strings.text('rentals.clear_search'),
                              onPressed: () => setState(() => _countrySearch = ''),
                              icon: const Icon(Icons.close_rounded),
                            ),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (countries.isNotEmpty)
                              Expanded(
                                child: _countryDropdown(
                                  visibleCountries,
                                  visibleCountries.any((item) => '${item['id']}' == selectedCountry) ? selectedCountry : null,
                                ),
                              ),
                            if (countries.isNotEmpty && durations.isNotEmpty)
                              const SizedBox(width: 12),
                            if (durations.isNotEmpty)
                              Expanded(
                                child: _durationDropdown(
                                  durations,
                                  selectedHours,
                                ),
                              ),
                          ],
                        )
                      else ...[
                        if (countries.isNotEmpty)
                          _countryDropdown(visibleCountries, visibleCountries.any((item) => '${item['id']}' == selectedCountry) ? selectedCountry : null),
                        if (countries.isNotEmpty && durations.isNotEmpty)
                          const SizedBox(height: 12),
                        if (durations.isNotEmpty)
                          _durationDropdown(durations, selectedHours),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                if (_error != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.cloud_off_rounded,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.strings.text('rentals.catalog_error', variables: {'error': _error ?? ''}),
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              height: 1.4,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: context.strings.text('rentals.retry'),
                          onPressed: _busy ? null : _loadCatalog,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ),

                if (_catalogLoading || _purchasePending)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: const LinearProgressIndicator(minHeight: 3),
                    ),
                  ),

                if (_catalog != null && visibleServices.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 32,
                    ),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.search_off_rounded, size: 42, color: muted),
                        const SizedBox(height: 12),
                        Text(
                          _catalogMode == 'app' && _serviceSearch.isNotEmpty
                              ? context.strings.text('rentals.no_app_results')
                              : context.strings.text('rentals.no_offers'),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.strings.text('rentals.try_another_filter'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted),
                        ),
                      ],
                    ),
                  ),

                // Catalogue adaptatif
                if (visibleServices.isNotEmpty)
                  LayoutBuilder(
                    builder: (context, gridConstraints) {
                      final width = gridConstraints.maxWidth;
                      final columns = width >= 1100
                          ? 3
                          : width >= 650
                          ? 2
                          : 1;

                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: visibleServices.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 126,
                        ),
                        itemBuilder: (context, index) {
                          final offer = Map<String, dynamic>.from(
                            visibleServices[index],
                          );
                          final stock = offer['stock'];
                          final noStock = stock is num && stock < 1;

                          return _RentalOfferCard(
                            name: '${offer['name'] ?? context.strings.text('rentals.service_fallback')}',
                            price: '${offer['customerPrice'] ?? '—'}',
                            stock: stock,
                            enabled: !_busy && !noStock,
                            onRent: () => _buy(offer),
                          );
                        },
                      );
                    },
                  ),

                const SizedBox(height: 30),
                Card(
                  elevation: 0,
                  child: ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(Icons.inventory_2_outlined, color: primary),
                    ),
                    title: Text(
                      context.strings.text('rentals.my_rentals'),
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(context.strings.text('rentals.description')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _showMyRentals,
                  ),
                ),
              ],
            );

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                32,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: content,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showMyRentals() async {
    setState(() {
      _rentalSearch = '';
      _rentalStatusFilter = 'TOUS';
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        final size = MediaQuery.sizeOf(sheetContext);
        final wide = size.width >= 760;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          width: wide ? 900 : double.infinity,
          height: size.height * (wide ? 0.90 : 0.94),
          alignment: Alignment.topCenter,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(wide ? 26 : 16, 4, wide ? 26 : 16, 28),
                child: _myRentalsContent(sheetContext),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _myRentalsContent(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.cardColor;
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
Row(
  children: [
    Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(Icons.inventory_2_outlined, color: primary),
    ),
    const SizedBox(width: 12),
    Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.strings.text('rentals.my_rentals'),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 3),
          Text(
            context.strings.text('rentals.description'),
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    IconButton.filledTonal(
      tooltip: context.strings.text('rentals.close_rentals'),
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.close_rounded),
    ),
  ],
),

const SizedBox(height: 18),

TextField(
  onChanged: (value) => setState(() => _rentalSearch = value.trim().toLowerCase()),
  decoration: InputDecoration(
    hintText: context.strings.text('rentals.rental_search_hint'),
    prefixIcon: const Icon(Icons.search_rounded),
    suffixIcon: _rentalSearch.isEmpty ? null : IconButton(
      tooltip: context.strings.text('rentals.clear_search'),
      onPressed: () => setState(() => _rentalSearch = ''),
      icon: const Icon(Icons.close_rounded),
    ),
    filled: true,
    fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
  ),
),
const SizedBox(height: 10),
SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: Row(
    children: ['TOUS', 'ACTIVE', 'PENDING', 'RECONCILIATION_REQUIRED', 'CANCELLED', 'EXPIRED'].map((filter) => Padding(
      padding: const EdgeInsets.only(right: 7),
      child: ChoiceChip(
        label: Text(filter == 'TOUS' ? context.strings.text('rentals.all') : filter == 'RECONCILIATION_REQUIRED' ? context.strings.text('rentals.to_check') : filter == 'ACTIVE' ? context.strings.text('rentals.active') : filter == 'PENDING' ? context.strings.text('rentals.pending') : filter == 'CANCELLED' ? context.strings.text('rentals.cancelled') : context.strings.text('rentals.expired')),
        selected: _rentalStatusFilter == filter,
        onSelected: (_) => setState(() => _rentalStatusFilter = filter),
      ),
    )).toList(),
  ),
),
const SizedBox(height: 12),

if (_client.auth.currentUser == null)
  Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Text(
      context.strings.text('rentals.sign_in_to_view'),
    ),
  )
else
  StreamBuilder<List<Map<String, dynamic>>>(
    stream: _client
        .from('proxnum_rentals')
        .stream(primaryKey: ['id'])
        .eq('user_id', _client.auth.currentUser!.id)
        .order('created_at', ascending: false),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _RentalNotice(
          icon: Icons.cloud_off_outlined,
          message:
              context.strings.text('rentals.history_error'),
        );
      }

      final allRows = snapshot.data ?? const <Map<String, dynamic>>[];
      final rows = allRows.where((rental) {
        final status = '${rental['status'] ?? 'UNKNOWN'}'.toUpperCase();
        final matchesStatus = _rentalStatusFilter == 'TOUS' || status == _rentalStatusFilter ||
            (_rentalStatusFilter == 'ACTIVE' && ['ACTIVE', 'SUCCESS', 'SUCCESSFUL', 'CONFIRMED'].contains(status));
        final haystack = [rental['service_name'], rental['service_code'], rental['country_name'], rental['country_code'], rental['phone_number'], rental['status']].join(' ').toLowerCase();
        return matchesStatus && (_rentalSearch.isEmpty || haystack.contains(_rentalSearch));
      }).toList();

      if (allRows.isEmpty || rows.isEmpty) {
        return _RentalNotice(
          icon: Icons.inbox_outlined,
          message: allRows.isEmpty
              ? context.strings.text('rentals.no_rentals')
              : context.strings.text('rentals.no_rental_results'),
        );
      }

      return Column(
        children: rows.map((rental) {
          final rentalId = rental['id'];
          final serviceName =
              rental['service_name'] ?? rental['service_code'];
          final countryName =
              rental['country_name'] ?? rental['country_code'];
          final status = '${rental['status'] ?? 'UNKNOWN'}';

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: theme.dividerColor.withValues(
                  alpha: 0.45,
                ),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 7,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                12,
                0,
                12,
                12,
              ),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.sim_card_rounded,
                  color: primary,
                ),
              ),
              title: Text(
                '$serviceName',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$countryName'),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      crossAxisAlignment:
                          WrapCrossAlignment.center,
                      children: [
                        _RentalBadge(
                          icon: Icons.circle,
                          label: _rentalStatusLabel(context, status),
                          color: _statusColor(status),
                        ),
                        Text(
                          '${rental['phone_number'] ?? context.strings.text('rentals.number_pending')}',
                          style: TextStyle(
                            color: muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              children: [
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.event_available_outlined,
                    color: primary,
                  ),
                  title: Text(context.strings.text('rentals.expiration')),
                  subtitle: Text(
                    '${rental['expires_at'] ?? context.strings.text('rentals.to_confirm')}',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.sync_rounded,
                    color: primary,
                  ),
                  title: Text(context.strings.text('rentals.synchronization')),
                  subtitle: Text(_syncLabel(rental)),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (rental['can_cancel'] == true)
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _cancel(rental),
                        icon: const Icon(Icons.cancel_outlined),
                        label: Text(context.strings.text('rentals.cancel')),
                      ),
                    if (rental['can_extend'] == true)
                      FilledButton.tonalIcon(
                        onPressed: _busy
                            ? null
                            : () => _extend(rental),
                        icon: const Icon(Icons.update_rounded),
                        label: Text(context.strings.text('rentals.renew')),
                      ),
                  ],
                ),
                if (rentalId is String) ...[
                  const SizedBox(height: 8),
                  _Messages(rentalId: rentalId),
                  _RentalActivity(rentalId: rentalId),
                ],
              ],
            ),
          );
        }).toList(),
      );
    },
  ),
      ],
    );
  }

  Widget _countryDropdown(List<Map> countries, String? selectedCountry) {
    return DropdownButtonFormField<String>(
      initialValue: selectedCountry,
      isExpanded: true,
      menuMaxHeight: 320,
      borderRadius: BorderRadius.circular(14),
      decoration: InputDecoration(
        labelText: context.strings.text('rentals.country'),
        prefixIcon: Icon(Icons.public_rounded),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      items: countries.map((item) {
        return DropdownMenuItem<String>(
          value: '${item['id']}',
          child: Text('${item['name']}', overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: _busy
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                _country = value;
                _catalog = null;
              });
              _loadCatalog();
            },
    );
  }

  Widget _durationDropdown(List<Map> durations, int? selectedHours) {
    return DropdownButtonFormField<int>(
      initialValue: selectedHours,
      isExpanded: true,
      menuMaxHeight: 320,
      borderRadius: BorderRadius.circular(14),
      decoration: InputDecoration(
        labelText: context.strings.text('rentals.duration'),
        prefixIcon: Icon(Icons.schedule_rounded),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      items: durations.map((item) {
        return DropdownMenuItem<int>(
          value: (item['hours'] as num).toInt(),
          child: Text('${item['label']}'),
        );
      }).toList(),
      onChanged: _busy
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                _hours = value;
                _catalog = null;
              });
              _loadCatalog();
            },
    );
  }

  String _rentalStatusLabel(BuildContext context, String status) {
    switch (status.toUpperCase()) {
      case 'ACTIVE':
      case 'SUCCESS':
      case 'SUCCESSFUL':
      case 'CONFIRMED':
        return context.strings.text('rentals.status.active');
      case 'PENDING':
      case 'CANCEL_PENDING':
      case 'CANCEL_REQUESTED':
      case 'RENEWAL_REQUESTED':
        return context.strings.text('rentals.status.pending');
      case 'CANCELLING':
        return context.strings.text('rentals.status.cancelling');
      case 'CANCELLED':
      case 'CANCELED':
        return context.strings.text('rentals.status.cancelled');
      case 'EXPIRED':
        return context.strings.text('rentals.status.expired');
      case 'FAILED':
        return context.strings.text('rentals.status.failed');
      case 'RECONCILIATION_REQUIRED':
        return context.strings.text('rentals.status.reconciliation');
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'ACTIVE':
      case 'SUCCESS':
      case 'SUCCESSFUL':
      case 'CONFIRMED':
        return Colors.green;
      case 'CANCELLED':
      case 'CANCELED':
      case 'EXPIRED':
      case 'FAILED':
        return Colors.red;
      case 'RECONCILIATION_REQUIRED':
      case 'CANCELLING':
      case 'PENDING':
      case 'RENEWAL_REQUESTED':
        return Colors.orange;
      default:
        return Colors.blueGrey;
    }
  }
}

class _RentalBadge extends StatelessWidget {
  const _RentalBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RentalOfferCard extends StatelessWidget {
  const _RentalOfferCard({
    required this.name,
    required this.price,
    required this.stock,
    required this.enabled,
    required this.onRent,
  });

  final String name;
  final String price;
  final dynamic stock;
  final bool enabled;
  final VoidCallback onRent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final noStock = stock is num && stock < 1;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.apps_rounded, color: primary, size: 21),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$price USD',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: primary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      noStock
                          ? context.strings.text('rentals.out_of_stock')
                          : context.strings.text('rentals.stock_count', variables: {'count': stock ?? context.strings.text('common.unavailable')}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: noStock ? Colors.red : muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: enabled ? onRent : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 10,
                  ),
                  minimumSize: const Size(0, 40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                child: Text(noStock ? context.strings.text('rentals.out_of_stock') : context.strings.text('rentals.rent')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RentalNotice extends StatelessWidget {
  const _RentalNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 28, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: const TextStyle(height: 1.4))),
        ],
      ),
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.rentalId});

  final String rentalId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Colors.teal;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12, bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.12), theme.cardColor],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.mark_unread_chat_alt_rounded, color: Colors.teal),
            ),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.strings.text('rentals.sms_messages'), style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 14)),
              SizedBox(height: 3),
              Text(context.strings.text('rentals.verification_codes'), style: TextStyle(fontSize: 12)),
            ])),
            const _SmsLiveBadge(),
          ]),
          const SizedBox(height: 12),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: Supabase.instance.client
                .from('proxnum_rental_messages')
                .stream(primaryKey: ['id'])
                .eq('rental_id', rentalId)
                .order('message_at', ascending: false),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
              }
              if (snapshot.hasError) {
                return _SmsInfoRow(icon: Icons.cloud_off_rounded, text: context.strings.text('rentals.sms_temporarily_unavailable'));
              }
              final messages = snapshot.data ?? const <Map<String, dynamic>>[];
              if (messages.isEmpty) {
                return _SmsInfoRow(icon: Icons.mark_email_unread_outlined, text: context.strings.text('rentals.no_sms'));
              }
              return Column(children: [
                Align(alignment: Alignment.centerLeft, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: accent.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(30)),
                  child: Text(context.strings.text(messages.length == 1 ? 'rentals.sms_received_one' : 'rentals.sms_received_many', variables: {'count': messages.length}), style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.w800, fontSize: 11)),
                )),
                const SizedBox(height: 8),
                ...messages.map((message) {
                  final body = _decodeSmsHtml('${message['message_text'] ?? context.strings.text('rentals.sms_content_unavailable')}');
                  final code = _smsVerificationCode(message, body);
                  final date = DateTime.tryParse('${message['message_at'] ?? ''}')?.toLocal();
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(15), border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35))),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(Icons.sms_rounded, size: 17, color: Colors.teal),
                        const SizedBox(width: 7),
                        Expanded(child: Text('${message['sender'] ?? context.strings.text('rentals.sms_sender')}', style: const TextStyle(fontWeight: FontWeight.w800))),
                        if (date != null) Text('${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                      ]),
                      const SizedBox(height: 9),
                      SelectableText(body, style: const TextStyle(height: 1.4)),
                      if (code.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(color: accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12), border: Border.all(color: accent.withValues(alpha: 0.30))),
                          child: Row(children: [
                            const Icon(Icons.password_rounded, color: Colors.teal, size: 20),
                            const SizedBox(width: 8),
                            Text(context.strings.text('rentals.code'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.teal, letterSpacing: 1)),
                            const SizedBox(width: 10),
                            Expanded(child: SelectableText(code, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2.2))),
                            IconButton(
                              tooltip: context.strings.text('rentals.copy_code'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: code));
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.strings.text('rentals.sms_copied'))));
                              },
                              icon: const Icon(Icons.copy_rounded, color: Colors.teal),
                            ),
                          ]),
                        ),
                      ],
                    ]),
                  );
                }),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

class _SmsLiveBadge extends StatefulWidget {
  const _SmsLiveBadge();
  @override
  State<_SmsLiveBadge> createState() => _SmsLiveBadgeState();
}

class _SmsLiveBadgeState extends State<_SmsLiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.08 + _controller.value * 0.10), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.teal.withValues(alpha: 0.20 + _controller.value * 0.25))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, color: Colors.teal, size: 7), SizedBox(width: 5), Text(context.strings.text('rentals.live'), style: TextStyle(color: Colors.teal, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.4))]),
    ),
  );
}

class _SmsInfoRow extends StatelessWidget {
  const _SmsInfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
    child: Row(children: [Icon(icon, color: Colors.teal, size: 22), const SizedBox(width: 10), Expanded(child: Text(text, style: const TextStyle(fontSize: 12, height: 1.45)))]),
  );
}

class _RentalActivity extends StatelessWidget {
  const _RentalActivity({required this.rentalId});

  final String rentalId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('proxnum_rental_ledger_entries')
          .stream(primaryKey: ['id'])
          .eq('rental_id', rentalId)
          .order('created_at', ascending: false),
      builder: (context, ledgerSnapshot) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(title: Text(context.strings.text('rentals.financial_history'))),
            if (ledgerSnapshot.hasError)
              ListTile(title: Text(context.strings.text('rentals.financial_unavailable'))),
            ...((ledgerSnapshot.data ?? const []).map((entry) {
              return ListTile(
                dense: true,
                title: Text(
                  '${entry['entry_type']} • '
                  '${entry['amount']} ${entry['currency']}',
                ),
                subtitle: Text('${entry['created_at']}'),
              );
            })),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: Supabase.instance.client
                  .from('proxnum_rental_operations')
                  .stream(primaryKey: ['id'])
                  .eq('rental_id', rentalId)
                  .order('created_at', ascending: false),
              builder: (context, operationSnapshot) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(title: Text(context.strings.text('rentals.operations_history'))),
                    if (operationSnapshot.hasError)
                      ListTile(title: Text(context.strings.text('rentals.operations_unavailable'))),
                    ...((operationSnapshot.data ?? const []).map((entry) {
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${entry['operation']} • ${entry['status']}',
                        ),
                        subtitle: Text('${entry['created_at']}'),
                      );
                    })),
                  ],
                );
              },
            ),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: Supabase.instance.client
                  .from('proxnum_rental_renewals')
                  .stream(primaryKey: ['id'])
                  .eq('rental_id', rentalId)
                  .order('created_at', ascending: false),
              builder: (context, renewalSnapshot) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      title: Text(context.strings.text('rentals.renewals_history')),
                    ),
                    if (renewalSnapshot.hasError)
                      ListTile(
                        title: Text(context.strings.text('rentals.renewals_unavailable')),
                      ),
                    ...((renewalSnapshot.data ?? const []).map((entry) {
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${entry['requested_hours']} h • '
                          '${entry['customer_price']} USD',
                        ),
                        subtitle: Text(
                          '${entry['status']} • ${entry['created_at']}',
                        ),
                      );
                    })),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}
