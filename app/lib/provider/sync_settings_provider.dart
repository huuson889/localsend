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
  SyncSettings init() => SyncSettings(
    syncPeerFingerprint: _persistence.getSyncPeerFingerprint(),
    clipboardSyncEnabled: _persistence.isClipboardSyncEnabled(),
    folderSyncEnabled: _persistence.isFolderSyncEnabled(),
    syncFolderPath: _persistence.getSyncFolderPath(),
  );

  Future<void> setSyncPeerFingerprint(String? fingerprint) async {
    await _persistence.setSyncPeerFingerprint(fingerprint);
    // Construct directly: copyWith cannot distinguish "keep" from "set null".
    state = SyncSettings(
      syncPeerFingerprint: fingerprint,
      clipboardSyncEnabled: state.clipboardSyncEnabled,
      folderSyncEnabled: state.folderSyncEnabled,
      syncFolderPath: state.syncFolderPath,
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
    state = SyncSettings(
      syncPeerFingerprint: state.syncPeerFingerprint,
      clipboardSyncEnabled: state.clipboardSyncEnabled,
      folderSyncEnabled: state.folderSyncEnabled,
      syncFolderPath: path,
    );
  }
}
