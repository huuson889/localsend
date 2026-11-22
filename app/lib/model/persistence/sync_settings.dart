/// Settings for paired-device sync (clipboard + shared folder).
///
/// The "paired" device is a [FavoriteDevice] selected by the user.
/// Trust comes from the existing fingerprint pinning (mTLS) and favorites:
/// sync only ever talks to this one peer, never broadcasts.
///
/// This is intentionally a plain model (not dart_mappable) so it can live
/// outside [SettingsState] without regenerating mappers.
class SyncSettings {
  /// Fingerprint of the paired (trusted) device, or null if none selected.
  final String? syncPeerFingerprint;

  /// Automatically sync clipboard text to/from the paired device on copy.
  final bool clipboardSyncEnabled;

  /// Automatically sync new/changed files in [syncFolderPath] both ways.
  final bool folderSyncEnabled;

  /// Local folder that is kept in sync with the paired device.
  final String? syncFolderPath;

  const SyncSettings({
    required this.syncPeerFingerprint,
    required this.clipboardSyncEnabled,
    required this.folderSyncEnabled,
    required this.syncFolderPath,
  });

  static const empty = SyncSettings(
    syncPeerFingerprint: null,
    clipboardSyncEnabled: false,
    folderSyncEnabled: false,
    syncFolderPath: null,
  );

  static const _unset = Object();

  /// Copies with the given fields replaced.
  /// Pass [_unset] (default) to keep a nullable field, or null to clear it.
  SyncSettings copyWith({
    Object? syncPeerFingerprint = _unset,
    bool? clipboardSyncEnabled,
    bool? folderSyncEnabled,
    Object? syncFolderPath = _unset,
  }) {
    return SyncSettings(
      syncPeerFingerprint: syncPeerFingerprint == _unset ? this.syncPeerFingerprint : syncPeerFingerprint as String?,
      clipboardSyncEnabled: clipboardSyncEnabled ?? this.clipboardSyncEnabled,
      folderSyncEnabled: folderSyncEnabled ?? this.folderSyncEnabled,
      syncFolderPath: syncFolderPath == _unset ? this.syncFolderPath : syncFolderPath as String?,
    );
  }

  /// Whether clipboard sync can run (peer selected + enabled).
  bool get clipboardSyncActive => clipboardSyncEnabled && syncPeerFingerprint != null;

  /// Whether folder sync can run (peer + folder selected + enabled).
  bool get folderSyncActive => folderSyncEnabled && syncPeerFingerprint != null && syncFolderPath != null;
}

/// File name used for clipboard-sync transfers.
///
/// Clipboard sync reuses the existing "message" transfer (a single text file
/// with an inline preview, see `message_preview.dart`), so no protocol change
/// is needed. The receiver recognizes this fixed name + paired sender and
/// applies the text to the clipboard instead of showing the receive dialog.
const clipboardSyncFileName = '__clipboard_sync__.txt';

/// Clipboard text larger than this is not synced.
///
/// It matches `maxMessagePreviewBytes` (16 KB): the text travels as the
/// message preview inside `prepare-upload`, so no file bytes are uploaded.
const maxClipboardSyncBytes = 16 * 1024;
