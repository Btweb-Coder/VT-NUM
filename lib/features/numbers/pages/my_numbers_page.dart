import 'package:flutter/material.dart';
import '../../../app/localization/app_localizations.dart';
import '../../../app/theme/colors.dart';

class MyNumbersPage extends StatelessWidget {
  const MyNumbersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.strings.text('numbers.title')),
      ),
      body: Center(
        child: Text(
          context.strings.text('numbers.empty'),
          style: TextStyle(
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
