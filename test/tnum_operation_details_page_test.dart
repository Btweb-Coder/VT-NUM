import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:online_sim/app/localization/app_localizations.dart';
import 'package:online_sim/core/services/catalog_bootstrap_service.dart';
import 'package:online_sim/features/activate/data/tnum_activation.dart';
import 'package:online_sim/features/activate/data/tnum_repository.dart';
import 'package:online_sim/features/activate/widgets/tnum_activation_panel.dart';
import 'package:online_sim/features/orders/pages/tnum_operation_details_page.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AppLocaleController> makeLocale() async {
    final locale = AppLocaleController();
    await locale.initialize();
    await locale.setLocale(const Locale('en'));
    return locale;
  }

  testWidgets(
    'purchase opens tracking immediately using returned activation.id',
    (tester) async {
      final locale = await makeLocale();
      final repository = _FakeTnumRepository();
      await tester.pumpWidget(
        AppLocaleScope(
          controller: locale,
          child: MaterialApp(
            home: Scaffold(
              body: TnumActivationPanel(
                repository: repository,
                catalogLoader: _catalog,
                countryRefresher: (_) async => _catalogValue(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(ElevatedButton).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Confirm and reserve'), findsOneWidget);
      await tester.tap(find.text('Confirm and reserve'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(TnumOperationDetailsPage), findsOneWidget);
      expect(repository.openedDetailIds, contains('created-activation-id'));
      expect(repository.detailRefreshOptions.first, isTrue);
      expect(find.text('Activation ordered successfully'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 51));
      locale.dispose();
    },
  );

  testWidgets('verification code appears before number and status', (
    tester,
  ) async {
    final locale = await makeLocale();
    final repository = _FakeTnumRepository(
      messages: [
        {
          'id': 'sms-1',
          'message_text': 'Your verification code is 482913',
          'code': '482913',
          'provider_sender': 'Example',
          'provider_received_at': '2026-11-04T10:00:00Z',
          'received_at': '2026-11-04T10:00:02Z',
        },
      ],
    );
    await tester.pumpWidget(
      AppLocaleScope(
        controller: locale,
        child: MaterialApp(
          home: TnumOperationDetailsPage(
            activationId: 'active-id',
            repository: repository,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final smsY = tester.getTopLeft(find.text('SMS')).dy;
    final codeY = tester.getTopLeft(find.text('482913')).dy;
    final numberY = tester.getTopLeft(find.text('+234800000001')).dy;
    final statusY = tester.getTopLeft(find.text('Status')).dy;
    expect(smsY, lessThan(numberY));
    expect(codeY, lessThan(numberY));
    expect(numberY, lessThan(statusY));
    expect(find.text('Your verification code is 482913'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 51));
    locale.dispose();
  });

  testWidgets('details automatically refresh from backend and reconnect', (
    tester,
  ) async {
    final locale = await makeLocale();
    final repository = _FakeTnumRepository(messages: <Map<String, dynamic>>[]);
    await tester.pumpWidget(
      AppLocaleScope(
        controller: locale,
        child: MaterialApp(
          home: TnumOperationDetailsPage(
            activationId: 'active-id',
            repository: repository,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(repository.detailRefreshOptions, contains(false));

    repository.messages.add({
      'id': 'sms-live',
      'message_text': 'Your code is 731204',
      'code': '731204',
      'received_at': '2026-11-04T10:00:00Z',
    });
    repository.changeCallback?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('731204'), findsOneWidget);

    final beforeReconnect = repository.openedDetailIds.length;
    repository.connectionCallback?.call(false);
    await tester.pump();
    expect(find.text('Reconnecting to activation updates...'), findsOneWidget);
    repository.connectionCallback?.call(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(repository.openedDetailIds.length, greaterThan(beforeReconnect));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 51));
    locale.dispose();
  });

  testWidgets(
    'current and historical activation cards open their own details',
    (tester) async {
      final locale = await makeLocale();
      final repository = _FakeTnumRepository(
        currentRows: [_activationRow('active-activation-id', 'active')],
        historyRows: [
          _activationRow('completed-activation-id', 'completed'),
          _activationRow('cancelled-activation-id', 'cancelled'),
        ],
      );
      await tester.pumpWidget(
        AppLocaleScope(
          controller: locale,
          child: MaterialApp(
            home: Scaffold(
              body: TnumActivationPanel(
                repository: repository,
                catalogLoader: _catalog,
                countryRefresher: (_) async => _catalogValue(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Card).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.openedDetailIds, contains('active-activation-id'));
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).first, const Offset(0, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.text('T-NUM history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(Card).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.openedDetailIds, contains('completed-activation-id'));
      expect(find.text('Completed'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Card).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.openedDetailIds, contains('cancelled-activation-id'));
      expect(find.text('Cancelled'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 51));
      locale.dispose();
    },
  );
}

Future<CatalogLoad<TnumCatalogSnapshot>> _catalog() async => _catalogValue();

CatalogLoad<TnumCatalogSnapshot> _catalogValue() => CatalogLoad(
  data: const TnumCatalogSnapshot(
    countries: [
      {'code': 234, 'name': 'Nigeria'},
    ],
    catalog: [
      {
        'service_slug': 'whatsapp',
        'country_code': 234,
        'services': {'name': 'WhatsApp'},
        'countries': {'name': 'Nigeria'},
        'customer_price_cents': 250,
        'available_count': 10,
      },
    ],
  ),
);

class _FakeTnumRepository extends TnumRepository {
  _FakeTnumRepository({
    List<Map<String, dynamic>> messages = const [],
    List<Map<String, dynamic>> currentRows = const [],
    List<Map<String, dynamic>> historyRows = const [],
  }) : this._(
         SupabaseClient('http://localhost:54321', 'tnum-details-test-key'),
         messages: messages,
         currentRows: currentRows,
         historyRows: historyRows,
       );

  _FakeTnumRepository._(
    this._testClient, {
    required this.messages,
    required this.currentRows,
    required this.historyRows,
  }) : super(client: _testClient) {
    // Supabase auth starts a periodic refresh timer when its client is built.
    // This fake never authenticates; stop it so widget tests do not leak timers.
    _testClient.auth.stopAutoRefresh();
  }

  final SupabaseClient _testClient;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> currentRows;
  final List<Map<String, dynamic>> historyRows;
  final List<String> openedDetailIds = [];
  final List<bool> detailRefreshOptions = [];
  void Function(bool connected)? connectionCallback;
  void Function()? changeCallback;

  @override
  Future<TnumQuote> quote(String service, int country) async => TnumQuote(
    id: 'quote-id',
    customerPriceCents: 250,
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
  );

  @override
  Future<Map<String, dynamic>> requestActivation({
    required String service,
    required int country,
    required String idempotencyKey,
    required String quoteId,
  }) async => {
    'activation': {'id': 'created-activation-id', 'status': 'active'},
  };

  @override
  Future<Map<String, dynamic>> poll() async => {'activations': currentRows};

  @override
  Future<List<Map<String, dynamic>>> activations({
    bool history = false,
  }) async => history ? historyRows : currentRows;

  @override
  Future<Map<String, dynamic>> details(
    String id, {
    bool refreshProvider = true,
  }) async {
    openedDetailIds.add(id);
    detailRefreshOptions.add(refreshProvider);
    return {
      'id': id,
      'status': id == 'completed-activation-id'
          ? 'completed'
          : id == 'cancelled-activation-id'
          ? 'cancelled'
          : 'active',
      'service_slug': 'whatsapp',
      'services': {'name': 'WhatsApp'},
      'country_code': 234,
      'countries': {'name': 'Nigeria'},
      'provider_operation_id': 12345,
      'phone_number': '+234800000001',
      'customer_price_cents': 250,
      'created_at': '2026-11-04T10:00:00Z',
      'provider_status': 'TZ_NUM_WAIT',
      'provider_time_remaining_seconds': 600,
      'last_provider_check_at': DateTime.now().toUtc().toIso8601String(),
      'activation_sms': messages,
      '_provider_state': {'status': 'TZ_NUM_WAIT', 'time': 600},
    };
  }

  @override
  RealtimeChannel watchActivation(
    String activationId, {
    required void Function() onChange,
    required void Function(bool connected) onConnection,
  }) {
    connectionCallback = onConnection;
    changeCallback = onChange;
    final channel = _testClient.channel('test-activation-$activationId');
    onConnection(true);
    return channel;
  }

  @override
  Future<void> removeActivationWatch(RealtimeChannel channel) async {}
}

Map<String, dynamic> _activationRow(String id, String status) => {
  'id': id,
  'status': status,
  'service_slug': 'whatsapp',
  'services': {'name': 'WhatsApp'},
  'country_code': 234,
  'countries': {'name': 'Nigeria'},
};
