import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Resolves the paired (trusted) sync peer to a dialable [Device].
///
/// Sync is only attempted while the peer is actually present in the
/// discovery list (with a known IP). There is deliberately no fallback to
/// the last-known IP from the favorites entry: a favorited device that is
/// offline or out of range must be waited for silently instead of being
/// retried (and reported as failing) on every poll. As soon as discovery
/// sees the peer again, pending changes are sent.
Device? resolveSyncPeer(Ref ref) {
  final fingerprint = ref.read(syncSettingsProvider).syncPeerFingerprint;
  if (fingerprint == null) {
    return null;
  }

  final discovered = ref.read(nearbyDevicesProvider).devices[fingerprint];
  if (discovered == null || discovered.ip == null) {
    return null;
  }
  return discovered;
}
