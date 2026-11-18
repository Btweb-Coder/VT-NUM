import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:online_sim/features/onboarding/first_time_app_guide.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      FirstTimeAppGuide.pendingPreferenceKey: true,
    });
  });

  testWidgets('auth guide advances through anchored steps and completes', (
    tester,
  ) async {
    var submitted = 0;
    late Future<void> guideFuture;
    await _mountAuthGuide(
      tester,
      onGuideStarted: (future) => guideFuture = future,
      onSubmit: () => submitted++,
    );

    expect(find.text('FIRST-TIME APP GUIDE'), findsOneWidget);
    expect(find.text('1/6'), findsOneWidget);

    for (var step = 0; step < 5; step++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    expect(find.text('6/6'), findsOneWidget);
    expect(find.text('CREATE ACCOUNT / LOG IN'), findsOneWidget);

    // The highlighted account-creation control is deliberately non-interactive
    // while the guide is explaining it.
    await tester.tap(
      find.byKey(
        FirstTimeAppGuide.anchorKey('auth', 'CREATE ACCOUNT / LOG IN'),
      ),
    );
    await tester.pump();
    expect(submitted, 0);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    await guideFuture;

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('online_sim_first_time_guide_done_auth'),
      isTrue,
    );
    expect(
      preferences.getBool(FirstTimeAppGuide.pendingPreferenceKey),
      isTrue,
    );
  });

  testWidgets('Skip disables the remaining first-time guide', (tester) async {
    late Future<void> guideFuture;
    await _mountAuthGuide(
      tester,
      onGuideStarted: (future) => guideFuture = future,
    );

    expect(find.text('FIRST-TIME APP GUIDE'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await guideFuture;

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(FirstTimeAppGuide.pendingPreferenceKey),
      isFalse,
    );
    expect(
      preferences.getBool('online_sim_first_time_guide_done_auth'),
      isNot(true),
    );
  });

  testWidgets('completed sections are not shown again', (tester) async {
    SharedPreferences.setMockInitialValues({
      FirstTimeAppGuide.pendingPreferenceKey: true,
      'online_sim_first_time_guide_done_auth': true,
    });

    var scheduled = false;
    late Future<void> guideFuture;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            if (!scheduled) {
              scheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                guideFuture = FirstTimeAppGuide.showIfNeeded(context, 'auth');
              });
            }
            return const Scaffold(body: Text('Sign in'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await guideFuture;

    expect(find.text('FIRST-TIME APP GUIDE'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

Future<void> _mountAuthGuide(
  WidgetTester tester, {
  required ValueChanged<Future<void>> onGuideStarted,
  VoidCallback? onSubmit,
}) async {
  var scheduled = false;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            if (!scheduled) {
              scheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onGuideStarted(
                  FirstTimeAppGuide.showIfNeeded(context, 'auth'),
                );
              });
            }

            return SingleChildScrollView(
              child: Column(
                children: [
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'ACCOUNT ENTRY',
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Create account'),
                    ),
                  ),
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'EMAIL FIELD',
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: TextField(decoration: InputDecoration(labelText: 'Email')),
                    ),
                  ),
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'PASSWORD FIELD',
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: TextField(decoration: InputDecoration(labelText: 'Password')),
                    ),
                  ),
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'REFERRAL CODE (OPTIONAL)',
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: TextField(decoration: InputDecoration(labelText: 'Referral code')),
                    ),
                  ),
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'TERMS CHECKBOX',
                    CheckboxListTile(
                      value: false,
                      onChanged: (_) {},
                      title: const Text('Accept terms'),
                    ),
                  ),
                  FirstTimeAppGuide.anchor(
                    'auth',
                    'CREATE ACCOUNT / LOG IN',
                    ElevatedButton(
                      onPressed: onSubmit,
                      child: const Text('Create account'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
}
