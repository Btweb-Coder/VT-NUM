import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:online_sim/app/localization/app_localizations.dart';
import 'package:online_sim/app/theme/colors.dart';
import 'package:online_sim/features/activate/data/tnum_repository.dart';
import 'package:online_sim/features/activate/widgets/tnum_feedback.dart';

void main() {
  test('maps known T-NUM failures to specific user messages', () {
    final insufficient = TnumFeedbackMessage.fromError(
      const TnumRepositoryException('INSUFFICIENT_FUNDS'),
    );
    expect(insufficient.titleKey, 'tnum.feedback.insufficient_title');

    final uncertain = TnumFeedbackMessage.fromError(
      const TnumRepositoryException('PENDING_PROVIDER_OPERATION'),
    );
    expect(uncertain.titleKey, 'tnum.feedback.processing_title');
    expect(uncertain.kind, TnumFeedbackKind.info);

    final outage = TnumFeedbackMessage.fromError(
      const TnumRepositoryException('PROVIDER_TIMEOUT'),
    );
    expect(outage.titleKey, 'tnum.feedback.server_title');

    final unknown = TnumFeedbackMessage.fromError(
      const TnumRepositoryException('UNRECOGNIZED_INTERNAL_CODE'),
    );
    expect(unknown.titleKey, 'tnum.feedback.unknown_title');
    expect(unknown.messageKey, 'tnum.feedback.unknown_body');
  });

  testWidgets('T-NUM feedback dialog follows the VT-NUM dialog style', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final locale = AppLocaleController();
    await locale.initialize();
    await locale.setLocale(const Locale('en'));
    await tester.pumpWidget(
      AppLocaleScope(
        controller: locale,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => TnumFeedbackDialog.show(
                  context,
                  title: 'Server temporarily unavailable',
                  message: 'Please try again later.',
                  kind: TnumFeedbackKind.warning,
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.backgroundColor, AppColors.surface);
    expect(
      (dialog.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text('Please try again later.'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    locale.dispose();
  });
}
