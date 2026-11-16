// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:online_sim/app/localization/app_localizations.dart';
import 'package:online_sim/app/router.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
    );
  });

  testWidgets('app builds', (WidgetTester tester) async {
    final localeController = AppLocaleController();
    await localeController.initialize();
    await tester.pumpWidget(
      AppLocaleScope(
        controller: localeController,
        child: const MaterialApp(home: AppRouter()),
      ),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    localeController.dispose();
  });
}
