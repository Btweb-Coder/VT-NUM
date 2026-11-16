import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLocaleController extends ChangeNotifier {
  static const _preferenceKey = 'vt_num_language';
  Locale _locale = const Locale('fr');
  Map<String, dynamic> _translations = const {};

  Locale get locale => _locale;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_preferenceKey);
    final systemLanguage = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    final language = saved == 'fr' || saved == 'en'
        ? saved!
        : (systemLanguage == 'en' ? 'en' : 'fr');
    await _load(language);
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    final language = locale.languageCode == 'en' ? 'en' : 'fr';
    if (_locale.languageCode == language && _translations.isNotEmpty) return;
    await SharedPreferences.getInstance().then(
      (preferences) => preferences.setString(_preferenceKey, language),
    );
    await _load(language);
    notifyListeners();
  }

  Future<void> _load(String language) async {
    final source = await rootBundle.loadString('assets/i18n/$language.json');
    _translations = jsonDecode(source) as Map<String, dynamic>;
    _locale = Locale(language);
  }

  String text(String key, {Map<String, Object?> variables = const {}}) {
    dynamic value = _translations;
    for (final part in key.split('.')) {
      if (value is! Map<String, dynamic>) break;
      value = value[part];
    }
    var result = value is String ? value : key;
    variables.forEach((name, replacement) {
      result = result.replaceAll('{$name}', '$replacement');
    });
    return result;
  }
}

class AppLocaleScope extends InheritedNotifier<AppLocaleController> {
  const AppLocaleScope({
    required AppLocaleController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppLocaleController controllerOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLocaleScope>()!.notifier!;
}

class AppStrings {
  const AppStrings(this.controller);

  final AppLocaleController controller;
  String text(String key, {Map<String, Object?> variables = const {}}) =>
      controller.text(key, variables: variables);
}

extension AppStringsContext on BuildContext {
  AppStrings get strings => AppStrings(AppLocaleScope.controllerOf(this));
}
