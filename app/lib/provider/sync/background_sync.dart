import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('BackgroundSync');

/// Keeps the Android foreground service alive while paired sync is active,
/// so the process (HTTP server, discovery, sync poll timers) is not killed
/// or frozen while the app is in the background. Without this, Android
/// suspends the app and auto sync only makes progress while the app is open.
///
/// The foreground service already exists for transfer progress
/// (see [TransferNotification]); this only adds a "keep-alive" hold on it.
/// Transfers take over the notification while they run and hand it back
/// afterwards.
///
/// No-op on non-Android platforms: desktop keeps running via the tray,
/// iOS does not allow this kind of background execution at all.
///
/// Must be called while the app is in the foreground (startup, settings
/// changes, app-resume): Android 12+ rejects foreground-service starts
/// from the background.
void updateSyncBackgroundService(Ref ref) {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }
  try {
    final settings = ref.read(syncSettingsProvider);
    if (settings.clipboardSyncActive || settings.folderSyncActive) {
      TransferNotification.setKeepAlive(
        title: 'Paired sync',
        text: 'Clipboard and folder sync with the paired device is running.',
      );
    } else {
      TransferNotification.clearKeepAlive();
    }
  } catch (e) {
    _logger.warning('Updating sync background service failed: $e');
  }
}
