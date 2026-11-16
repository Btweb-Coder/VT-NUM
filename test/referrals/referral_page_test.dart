import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:online_sim/app/localization/app_localizations.dart';
import 'package:online_sim/features/referrals/data/referral_repository.dart';
import 'package:online_sim/features/referrals/pages/referral_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('referral code remains hidden until qualification is complete', (
    tester,
  ) async {
    final locale = await _makeLocale();
    final repository = _FakeReferralRepository(
      dashboard: _dashboard(
        unlocked: false,
        code: 'HIDDEN42',
        eligibleActivations: 1,
      ),
    );

    await tester.pumpWidget(_app(locale, repository));
    await tester.pumpAndSettle();

    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('HIDDEN42'), findsNothing);
    expect(find.byTooltip('Copy referral code'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    locale.dispose();
  });

  testWidgets('unlocked referral code is displayed with copy action', (
    tester,
  ) async {
    final locale = await _makeLocale();
    final repository = _FakeReferralRepository(
      dashboard: _dashboard(
        unlocked: true,
        code: 'READY42',
        eligibleActivations: 2,
      ),
    );

    await tester.pumpWidget(_app(locale, repository));
    await tester.pumpAndSettle();

    expect(find.text('READY42'), findsOneWidget);
    expect(find.byTooltip('Copy referral code'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    locale.dispose();
  });

  testWidgets('withdrawal dialog estimates FCFA and submits entered details', (
    tester,
  ) async {
    final locale = await _makeLocale();
    final repository = _FakeReferralRepository(
      dashboard: _dashboard(
        unlocked: true,
        code: 'READY42',
        eligibleActivations: 2,
        availableBalance: 20,
        rate: 630,
      ),
    );

    await tester.pumpWidget(_app(locale, repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Request a withdrawal'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));

    await tester.enterText(fields.at(0), '5');
    await tester.pump();
    expect(find.text('Estimated payout: 3150 FCFA'), findsOneWidget);

    await tester.enterText(fields.at(1), 'Test User');
    await tester.enterText(fields.at(2), '670000000');
    await tester.tap(find.text('Submit request'));
    await tester.pumpAndSettle();

    expect(repository.requestedAmount, 5);
    expect(repository.requestedNetwork, 'MTN_MOMO');
    expect(repository.requestedAccountName, 'Test User');
    expect(repository.requestedPhoneNumber, '670000000');
    expect(
      find.text('Your withdrawal request has been submitted for manual processing.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    locale.dispose();
  });

  testWidgets('referral history displays invited users and deposit rewards', (
    tester,
  ) async {
    final locale = await _makeLocale();
    final repository = _FakeReferralRepository(
      dashboard: _dashboard(
        unlocked: true,
        code: 'READY42',
        eligibleActivations: 2,
      ),
      history: {
        'referrals': [
          {
            'user_id': '12345678-abcd-efgh',
            'successful_deposits': 1,
            'commission_usd': 0.50,
            'joined_at': '2026-11-10T10:00:00Z',
          },
        ],
        'commission_events': [
          {
            'referee_user_id': '87654321-abcd-efgh',
            'amount_usd': 0.50,
            'created_at': '2026-11-11T10:00:00Z',
          },
        ],
        'withdrawals': [],
      },
    );

    await tester.pumpWidget(_app(locale, repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Referral history'));
    await tester.pumpAndSettle();

    expect(find.text('12345678…'), findsOneWidget);
    expect(find.text('+\\$0.50'), findsOneWidget);
    expect(repository.historyRequests, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    locale.dispose();
  });
}

Future<AppLocaleController> _makeLocale() async {
  final locale = AppLocaleController();
  await locale.initialize();
  await locale.setLocale(const Locale('en'));
  return locale;
}

Widget _app(
  AppLocaleController locale,
  ReferralRepository repository,
) {
  return AppLocaleScope(
    controller: locale,
    child: MaterialApp(
      home: ReferralPage(repository: repository),
    ),
  );
}

Map<String, dynamic> _dashboard({
  required bool unlocked,
  required String code,
  required int eligibleActivations,
  double availableBalance = 0,
  double rate = 630,
}) {
  return {
    'referral_code': code,
    'code_unlocked': unlocked,
    'eligible_activations': eligibleActivations,
    'referred_users': 1,
    'successful_deposits': 1,
    'total_earned_usd': 0.50,
    'available_balance_usd': availableBalance,
    'total_withdrawn_usd': 0,
    'commission_per_deposit_usd': 0.50,
    'minimum_withdrawal_usd': 5,
    'maximum_withdrawal_usd': 100,
    'usd_to_xaf_rate': rate,
  };
}

class _FakeReferralRepository extends ReferralRepository {
  factory _FakeReferralRepository({
    required Map<String, dynamic> dashboard,
    Map<String, dynamic> history = const {
      'referrals': [],
      'commission_events': [],
      'withdrawals': [],
    },
  }) {
    final client = SupabaseClient(
      'http://localhost:54321',
      'referral-page-test-key',
    );
    return _FakeReferralRepository._(
      dashboard: dashboard,
      history: history,
      client: client,
    );
  }

  _FakeReferralRepository._({
    required this.dashboard,
    required this.history,
    required SupabaseClient client,
  }) : super(client: client) {
    client.auth.stopAutoRefresh();
  }

  final Map<String, dynamic> dashboard;
  final Map<String, dynamic> history;
  int historyRequests = 0;
  double? requestedAmount;
  String? requestedNetwork;
  String? requestedAccountName;
  String? requestedPhoneNumber;

  @override
  Future<Map<String, dynamic>> getDashboard() async => dashboard;

  @override
  Future<Map<String, dynamic>> getHistory({int limit = 100}) async {
    historyRequests++;
    return history;
  }

  @override
  Future<String> requestWithdrawal({
    required double amountUsd,
    required String network,
    required String accountName,
    required String phoneNumber,
  }) async {
    requestedAmount = amountUsd;
    requestedNetwork = network;
    requestedAccountName = accountName;
    requestedPhoneNumber = phoneNumber;
    return 'test-withdrawal-id';
  }
}
