import 'package:flutter_test/flutter_test.dart';
import 'package:online_sim/core/services/app_update_service.dart';

void main() {
  const forcedUpdate = AppUpdateInfo(
    requiredVersion: '1.1.2',
    downloadUrl: 'https://downloads.example.com/online-sim-1.1.2.apk',
    forceUpdate: true,
  );

  test('allows only the configured sideloaded app version', () {
    expect(forcedUpdate.requiresUpdate('1.1.1'), isTrue);
    expect(forcedUpdate.requiresUpdate('1.1.2'), isFalse);
    expect(forcedUpdate.requiresUpdate('1.1.3'), isTrue);
    expect(forcedUpdate.requiresUpdate('1.1.2+17'), isFalse);
  });

  test('does not gate when disabled or when the download URL is invalid', () {
    const disabled = AppUpdateInfo(
      requiredVersion: '1.1.2',
      downloadUrl: 'https://downloads.example.com/app.apk',
      forceUpdate: false,
    );
    const invalidUrl = AppUpdateInfo(
      requiredVersion: '1.1.2',
      downloadUrl: 'not-a-url',
      forceUpdate: true,
    );

    expect(disabled.requiresUpdate('1.0.0'), isFalse);
    expect(invalidUrl.requiresUpdate('1.0.0'), isFalse);
  });
}
