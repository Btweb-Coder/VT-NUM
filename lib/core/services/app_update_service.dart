
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.requiredVersion,
    required this.downloadUrl,
    required this.forceUpdate,
  });

  final String requiredVersion;
  final String downloadUrl;
  final bool forceUpdate;

  factory AppUpdateInfo.fromMap(Map<String, dynamic> data) {
    return AppUpdateInfo(
      requiredVersion:
          (data['required_version'] as String? ?? '').trim(),
      downloadUrl:
          (data['download_url'] as String? ?? '').trim(),
      forceUpdate: data['force_update'] == true,
    );
  }

  bool requiresUpdate(String installedVersion) {
    if (!forceUpdate ||
        requiredVersion.isEmpty ||
        Uri.tryParse(downloadUrl)?.hasScheme != true) {
      return false;
    }

    return _normaliseVersion(installedVersion) !=
        _normaliseVersion(requiredVersion);
  }

  static String _normaliseVersion(String value) =>
      value.trim().split('+').first;
}

class AppUpdateService {
  AppUpdateService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Stream<AppUpdateInfo> watch() {
    return _client
        .from('app_update_config')
        .stream(primaryKey: ['id'])
        .map((rows) {
      debugPrint('APP UPDATE ROWS: $rows');

      final row = rows.isEmpty
          ? <String, dynamic>{}
          : rows.first;

      final update = AppUpdateInfo.fromMap(row);

      debugPrint(
        'APP UPDATE CONFIG: '
        'force=${update.forceUpdate}, '
        'required=${update.requiredVersion}, '
        'url=${update.downloadUrl}',
      );

      return update;
    });
  }
}
