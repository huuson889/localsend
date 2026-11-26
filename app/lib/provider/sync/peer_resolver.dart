import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Resolves the paired (trusted) sync peers to dialable [Device]s.
///
/// Sync with a peer is only attempted while that peer is actually present
/// in the discovery list (with a known IP). There is deliberately no
/// fallback to the last-known IP from the favorites entry: a paired device
/// that is offline or out of range must be waited for silently instead of
/// being retried (and reported as failing) on every poll. As soon as
/// discovery sees the peer again, pending changes are sent to it. Peers
/// are independent: one peer being offline never blocks sync with another.
List<Device> resolveSyncPeers(Ref ref) {
  final fingerprints = ref.read(syncSettingsProvider).syncPeerFingerprints;
  if (fingerprints.isEmpty) {
    return const [];
  }
  final devices = ref.read(nearbyDevicesProvider).devices;
  final result = <Device>[];
  for (final fingerprint in fingerprints) {
    final device = devices[fingerprint];
    if (device != null && device.ip != null) {
      result.add(device);
    }
  }
  return result;
}

/// Whether the paired peer [fingerprint] is currently discovered with an
/// IP (i.e. sync with it would be attempted right now).
bool isSyncPeerOnline(Ref ref, String fingerprint) {
  final device = ref.read(nearbyDevicesProvider).devices[fingerprint];
  return device != null && device.ip != null;
}
