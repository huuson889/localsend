import 'package:localsend_app/model/persistence/sync_settings.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Holds the paired-device sync settings (clipboard + shared folder).
///
/// Kept separate from [SettingsState] on purpose: it avoids regenerating
/// dart_mappable code and keeps the sync feature self-contained.
final syncSettingsProvider = NotifierProvider<SyncSettingsService, SyncSettings>((ref) {
  return SyncSettingsService(ref.read(persistenceProvider));
});

class SyncSettingsService extends PureNotifier<SyncSettings> {
  final PersistenceService _persistence;

  SyncSettingsService(this._persistence);

  @override
  SyncSettings init() {
    final peers = _persistence.getSyncPeerFingerprints();
    return SyncSettings(
      syncPeerFingerprints: peers,
      clipboardSyncEnabled: _persistence.isClipboardSyncEnabled(),
      folderSyncEnabled: _persistence.isFolderSyncEnabled(),
      syncFolderPath: _persistence.getSyncFolderPath(),
      screenshotSyncEnabled: _persistence.isScreenshotSyncEnabled(),
      clipboardConfirmedPeerFingerprints: _persistence.getSyncClipboardConfirmedFingerprints().toSet(),
      folderConfirmedPeerFingerprints: _persistence.getSyncFolderConfirmedFingerprints().toSet(),
    );
  }

  /// Adds [fingerprint] to the paired sync peers (no-op if already paired).
  /// Existing peers are kept: pairing is multi-device, each pair syncs
  /// independently.
  Future<void> addSyncPeerFingerprint(String fingerprint) async {
    if (state.syncPeerFingerprints.contains(fingerprint)) {
      return;
    }
    final peers = [...state.syncPeerFingerprints, fingerprint];
    await _persistence.setSyncPeerFingerprints(peers);
    state = state.copyWith(syncPeerFingerprints: peers);
  }

  /// Removes [fingerprint] from the paired sync peers, including its
  /// per-feature confirmation state.
  Future<void> removeSyncPeerFingerprint(String fingerprint) async {
    if (!state.syncPeerFingerprints.contains(fingerprint)) {
      return;
    }
    final peers = state.syncPeerFingerprints.where((e) => e != fingerprint).toList();
    final clipboardConfirmed = state.clipboardConfirmedPeerFingerprints.where((e) => e != fingerprint).toSet();
    final folderConfirmed = state.folderConfirmedPeerFingerprints.where((e) => e != fingerprint).toSet();
    await _persistence.setSyncPeerFingerprints(peers);
    await _persistence.setSyncClipboardConfirmedFingerprints(clipboardConfirmed.toList());
    await _persistence.setSyncFolderConfirmedFingerprints(folderConfirmed.toList());
    state = state.copyWith(
      syncPeerFingerprints: peers,
      clipboardConfirmedPeerFingerprints: clipboardConfirmed,
      folderConfirmedPeerFingerprints: folderConfirmed,
    );
  }

  Future<void> setClipboardSyncEnabled(bool enabled) async {
    await _persistence.setClipboardSyncEnabled(enabled);
    state = state.copyWith(clipboardSyncEnabled: enabled);
  }

  Future<void> setScreenshotSyncEnabled(bool enabled) async {
    await _persistence.setScreenshotSyncEnabled(enabled);
    state = state.copyWith(screenshotSyncEnabled: enabled);
  }

  Future<void> setFolderSyncEnabled(bool enabled) async {
    await _persistence.setFolderSyncEnabled(enabled);
    state = state.copyWith(folderSyncEnabled: enabled);
  }

  Future<void> setSyncFolderPath(String? path) async {
    await _persistence.setSyncFolderPath(path);
    state = state.copyWith(syncFolderPath: path);
  }

  /// Records (or clears) the proof that [fingerprint] also enabled
  /// clipboard sync back. Called when a clipboard sync is accepted by that
  /// peer, when one is received from it, or when that peer rejects one.
  Future<void> setClipboardPeerConfirmed(String fingerprint, bool confirmed) async {
    final updated = {...state.clipboardConfirmedPeerFingerprints};
    if (confirmed) {
      updated.add(fingerprint);
    } else {
      updated.remove(fingerprint);
    }
    if (updated.length == state.clipboardConfirmedPeerFingerprints.length &&
        updated.containsAll(state.clipboardConfirmedPeerFingerprints)) {
      return;
    }
    await _persistence.setSyncClipboardConfirmedFingerprints(updated.toList());
    state = state.copyWith(clipboardConfirmedPeerFingerprints: updated);
  }

  /// Same as [setClipboardPeerConfirmed], for folder sync.
  Future<void> setFolderPeerConfirmed(String fingerprint, bool confirmed) async {
    final updated = {...state.folderConfirmedPeerFingerprints};
    if (confirmed) {
      updated.add(fingerprint);
    } else {
      updated.remove(fingerprint);
    }
    if (updated.length == state.folderConfirmedPeerFingerprints.length &&
        updated.containsAll(state.folderConfirmedPeerFingerprints)) {
      return;
    }
    await _persistence.setSyncFolderConfirmedFingerprints(updated.toList());
    state = state.copyWith(folderConfirmedPeerFingerprints: updated);
  }
}
