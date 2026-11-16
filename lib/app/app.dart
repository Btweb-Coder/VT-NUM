import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'localization/app_localizations.dart';
import '../features/app_update/app_update_gate.dart';
import 'theme/app_theme.dart';

class VirtualSmsApp extends StatefulWidget {
  const VirtualSmsApp({super.key});

  @override
  State<VirtualSmsApp> createState() => _VirtualSmsAppState();
}

class _VirtualSmsAppState extends State<VirtualSmsApp> {
  late final AppLocaleController _localeController = AppLocaleController();

  @override
  void initState() {
    super.initState();
    _localeController.initialize();
  }

  @override
  void dispose() {
    _localeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppLocaleScope(
      controller: _localeController,
      child: AnimatedBuilder(
        animation: _localeController,
        builder: (context, _) => MaterialApp(
          title: 'VT NUM',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          locale: _localeController.locale,
          supportedLocales: const [Locale('fr'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => child ?? const SizedBox.shrink(),
          home: const AppUpdateGate(),
        ),
      ),
    );
  }
}
