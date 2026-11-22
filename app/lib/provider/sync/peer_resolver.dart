import 'package:collection/collection.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Resolves the paired (trusted) sync peer to a dialable [Device].
///
/// Prefers the currently discovered device. When the peer is not in the
/// discovery map right now (announcements are best-effort and the entry may
/// be missing while the peer is actually reachable), falls back to the
/// address stored in the favorites entry the user paired with. This is the
/// same fingerprint-pinned trust model as quickSave-from-favorites: the
/// transfer still only ever goes to the one paired fingerprint, and the TLS
/// client stays pinned to it.
Device? resolveSyncPeer(Ref ref) {
  final fingerprint = ref.read(syncSettingsProvider).syncPeerFingerprint;
  if (fingerprint == null) {
    return null;
  }

  final discovered = ref.read(nearbyDevicesProvider).devices[fingerprint];
  if (discovered != null && discovered.ip != null) {
    return discovered;
  }

  final favorite = ref
      .read(favoritesProvider)
      .firstWhereOrNull((e) => e.fingerprint == fingerprint);
  if (favorite == null) {
    return null;
  }
  final https = ref.read(settingsProvider).https;
  return Device(
    signalingId: null,
    ip: favorite.ip,
    version: '',
    port: favorite.port,
    https: https,
    fingerprint: favorite.fingerprint,
    alias: favorite.alias,
    deviceModel: null,
    deviceType: DeviceType.desktop,
    download: false,
    channels: [
      HttpChannel(host: favorite.ip, port: favorite.port, https: https),
    ],
  );
}
