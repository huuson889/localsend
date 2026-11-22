import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/sync_settings.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/sync/background_sync.dart';
import 'package:localsend_app/provider/sync/clipboard_sync_service.dart';
import 'package:localsend_app/provider/sync/folder_sync_service.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/ui/sync_toast.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('Pairing');

/// How long a pairing PIN stays valid.
const pairingTimeout = Duration(seconds: 60);

/// An outgoing pairing request: this device tapped the heart on [device]
/// and is waiting for the other side to confirm the PIN.
class OutgoingPairing {
  final Device device;
  final String pin;
  final DateTime expiresAt;

  const OutgoingPairing({required this.device, required this.pin, required this.expiresAt});
}

/// An incoming pairing request: [sender] tapped the heart on this device
/// and is waiting for the user here to confirm the PIN.
class IncomingPairing {
  final Device sender;
  final String pin;
  final DateTime expiresAt;

  const IncomingPairing({required this.sender, required this.pin, required this.expiresAt});
}

class PairingState {
  final OutgoingPairing? outgoing;
  final IncomingPairing? incoming;

  const PairingState({this.outgoing, this.incoming});

  static const empty = PairingState();
}

final pairingProvider = NotifierProvider<PairingService, PairingState>((ref) {
  return PairingService();
});

/// PIN-based pairing for auto sync.
///
/// Tapping the heart on a discovered device no longer favorites it
/// instantly. Instead this service sends a pairing request (a tiny text
/// payload riding the normal message transfer, see [pairingSyncFileName])
/// and shows a 6-digit PIN on both devices. Only when the other side
/// accepts while seeing the same PIN do both devices save each other as
/// favorite + sync peer. Requests expire after [pairingTimeout].
///
/// Pairing only establishes the favorite/peer relationship; the actual
/// clipboard/folder features still have to be enabled on both devices.
class PairingService extends Notifier<PairingState> {
  Timer? _outgoingTimer;
  Timer? _incomingTimer;

  @override
  PairingState init() => PairingState.empty;

  /// Starts a pairing request to [target] (heart tap on a device that is
  /// not a favorite yet).
  Future<void> startPairing(Device target) async {
    if (state.outgoing != null) {
      return;
    }
    final pin = (Random.secure().nextInt(900000) + 100000).toString();
    state = PairingState(
      outgoing: OutgoingPairing(device: target, pin: pin, expiresAt: DateTime.now().add(pairingTimeout)),
      incoming: state.incoming,
    );
    _outgoingTimer?.cancel();
    _outgoingTimer = Timer(pairingTimeout, () {
      if (state.outgoing?.pin == pin) {
        state = PairingState(incoming: state.incoming);
        showSyncToastLocalized(en: 'Pairing timed out', vi: 'Ghép cặp hết thời gian chờ');
      }
    });
    await _sendPayload(target, 'PAIR1|REQ|$pin');
  }

  /// Cancels the outgoing request (user pressed Cancel while waiting).
  void cancelOutgoing() {
    _outgoingTimer?.cancel();
    state = PairingState(incoming: state.incoming);
  }

  /// Handles a pairing payload received from [sender]. Called by
  /// `ReceiveController` for sessions carrying [pairingSyncFileName].
  void handlePayload({required Device sender, required String payload}) {
    final parts = payload.split('|');
    if (parts.length < 3 || parts[0] != 'PAIR1') {
      return;
    }
    if (parts[1] == 'REQ') {
      if (state.incoming != null) {
        // Already showing a pairing request: ignore additional ones.
        return;
      }
      final pin = parts[2];
      state = PairingState(
        outgoing: state.outgoing,
        incoming: IncomingPairing(sender: sender, pin: pin, expiresAt: DateTime.now().add(pairingTimeout)),
      );
      _incomingTimer?.cancel();
      _incomingTimer = Timer(pairingTimeout, () {
        if (state.incoming?.pin == pin) {
          state = PairingState(outgoing: state.outgoing);
        }
      });
      return;
    }
    if (parts[1] == 'RESP' && parts.length >= 4) {
      final outgoing = state.outgoing;
      if (outgoing == null || outgoing.device.fingerprint != sender.fingerprint || outgoing.pin != parts[3]) {
        return;
      }
      if (parts[2] == 'ACCEPT') {
        _completeOutgoingPairing(); // ignore: unawaited_futures
      } else {
        _outgoingTimer?.cancel();
        state = PairingState(incoming: state.incoming);
        showSyncToastLocalized(
          en: '${outgoing.device.alias} declined the pairing',
          vi: '${outgoing.device.alias} đã từ chối ghép cặp',
        );
      }
    }
  }

  /// The user accepted the incoming request on this device: save the
  /// sender as favorite + sync peer and tell it the good news.
  Future<void> acceptIncoming() async {
    final incoming = state.incoming;
    if (incoming == null) {
      return;
    }
    _incomingTimer?.cancel();
    state = PairingState(outgoing: state.outgoing);
    await _savePairing(incoming.sender);
    await _sendPayload(_dialableDevice(incoming.sender), 'PAIR1|RESP|ACCEPT|${incoming.pin}');
    showSyncToastLocalized(
      en: 'Paired with ${incoming.sender.alias}',
      vi: 'Đã ghép cặp với ${incoming.sender.alias}',
    );
  }

  /// The user declined the incoming request on this device.
  Future<void> declineIncoming() async {
    final incoming = state.incoming;
    if (incoming == null) {
      return;
    }
    _incomingTimer?.cancel();
    state = PairingState(outgoing: state.outgoing);
    await _sendPayload(_dialableDevice(incoming.sender), 'PAIR1|RESP|DECLINE|${incoming.pin}');
  }

  /// The outgoing request was accepted by the peer: save it as favorite +
  /// sync peer on this side too.
  Future<void> _completeOutgoingPairing() async {
    final outgoing = state.outgoing;
    if (outgoing == null) {
      return;
    }
    _outgoingTimer?.cancel();
    state = PairingState(incoming: state.incoming);
    await _savePairing(outgoing.device);
    showSyncToastLocalized(
      en: 'Paired with ${outgoing.device.alias}',
      vi: 'Đã ghép cặp với ${outgoing.device.alias}',
    );
  }

  /// Saves [device] as favorite (if not already) and selects it as the
  /// sync peer. Nothing is sent yet: sync starts with the next
  /// copy/change, once both sides enabled the same feature.
  Future<void> _savePairing(Device device) async {
    final ip = device.ip;
    if (ip != null && !ref.read(favoritesProvider).any((e) => e.fingerprint == device.fingerprint)) {
      await ref.redux(favoritesProvider).dispatchAsync(
            AddFavoriteAction(
              FavoriteDevice.fromValues(fingerprint: device.fingerprint, ip: ip, port: device.port, alias: device.alias),
            ),
          );
    }
    await ref.notifier(syncSettingsProvider).setSyncPeerFingerprint(device.fingerprint);
    updateSyncBackgroundService(ref);
    ref.notifier(clipboardSyncProvider).primeCache(); // ignore: unawaited_futures
    ref.notifier(folderSyncProvider).pollNow(); // ignore: unawaited_futures
  }

  /// Resolves [device] to something dialable: the discovered instance if
  /// available, otherwise the device as reported in its own payload.
  Device _dialableDevice(Device device) {
    final discovered = ref.read(nearbyDevicesProvider).devices[device.fingerprint];
    if (discovered != null && discovered.ip != null) {
      return discovered;
    }
    return device;
  }

  /// Sends a pairing payload as a background message transfer. The
  /// receiver recognizes [pairingSyncFileName] in `ReceiveController` and
  /// never shows a receive dialog for it.
  Future<void> _sendPayload(Device target, String payload) async {
    try {
      final bytes = utf8.encode(payload);
      final file = CrossFile(
        name: pairingSyncFileName,
        fileType: FileType.text,
        size: bytes.length,
        thumbnail: null,
        asset: null,
        path: null,
        bytes: bytes,
        lastModified: null,
        lastAccessed: null,
      );
      await ref.notifier(sendProvider).startSession(target: target, files: [file], background: true);
    } catch (e) {
      _logger.warning('Sending pairing payload failed: $e');
    }
  }
}
