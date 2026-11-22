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
    final peer = _persistence.getSyncPeerFingerprint();
    return SyncSettings(
      syncPeerFingerprint: peer,
      clipboardSyncEnabled: _persistence.isClipboardSyncEnabled(),
      folderSyncEnabled: _persistence.isFolderSyncEnabled(),
      syncFolderPath: _persistence.getSyncFolderPath(),
      clipboardPeerConfirmed: peer != null && _persistence.getSyncClipboardConfirmedFingerprint() == peer,
      folderPeerConfirmed: peer != null && _persistence.getSyncFolderConfirmedFingerprint() == peer,
    );
  }

  Future<void> setSyncPeerFingerprint(String? fingerprint) async {
    await _persistence.setSyncPeerFingerprint(fingerprint);
    // Construct directly: copyWith cannot distinguish "keep" from "set null".
    // The confirmed flags only carry over when a previous confirmation
    // exists for exactly this peer.
    state = SyncSettings(
      syncPeerFingerprint: fingerprint,
      clipboardSyncEnabled: state.clipboardSyncEnabled,
      folderSyncEnabled: state.folderSyncEnabled,
      syncFolderPath: state.syncFolderPath,
      clipboardPeerConfirmed: fingerprint != null && _persistence.getSyncClipboardConfirmedFingerprint() == fingerprint,
      folderPeerConfirmed: fingerprint != null && _persistence.getSyncFolderConfirmedFingerprint() == fingerprint,
    );
  }

  Future<void> setClipboardSyncEnabled(bool enabled) async {
    await _persistence.setClipboardSyncEnabled(enabled);
    state = state.copyWith(clipboardSyncEnabled: enabled);
  }

  Future<void> setFolderSyncEnabled(bool enabled) async {
    await _persistence.setFolderSyncEnabled(enabled);
    state = state.copyWith(folderSyncEnabled: enabled);
  }

  Future<void> setSyncFolderPath(String? path) async {
    await _persistence.setSyncFolderPath(path);
    state = state.copyWith(syncFolderPath: path);
  }

  /// Records (or clears) the proof that the current peer also enabled
  /// clipboard sync back. Called when a clipboard sync is accepted by the
  /// peer, when one is received from it, or when the peer rejects one.
  Future<void> setClipboardPeerConfirmed(bool confirmed) async {
    final peer = state.syncPeerFingerprint;
    await _persistence.setSyncClipboardConfirmedFingerprint(confirmed && peer != null ? peer : null);
    state = state.copyWith(clipboardPeerConfirmed: confirmed && peer != null);
  }

  /// Same as [setClipboardPeerConfirmed], for folder sync.
  Future<void> setFolderPeerConfirmed(bool confirmed) async {
    final peer = state.syncPeerFingerprint;
    await _persistence.setSyncFolderConfirmedFingerprint(confirmed && peer != null ? peer : null);
    state = state.copyWith(folderPeerConfirmed: confirmed && peer != null);
  }
}
