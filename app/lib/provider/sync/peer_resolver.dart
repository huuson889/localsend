import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Resolves the paired (trusted) sync peer to a dialable [Device].
///
/// Only devices currently discovered on the LAN are returned: sync must not
/// dial a stale favorite IP. If the peer is not discovered (app closed,
/// different network), this returns null and the sync services retry later.
Device? resolveSyncPeerOnline(Ref ref) {
  final fingerprint = ref.read(syncSettingsProvider).syncPeerFingerprint;
  if (fingerprint == null) {
    return null;
  }
  final device = ref.read(nearbyDevicesProvider).devices[fingerprint];
  if (device == null || device.ip == null) {
    return null;
  }
  return device;
}
