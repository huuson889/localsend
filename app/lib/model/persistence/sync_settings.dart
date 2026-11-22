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

  /// Whether the peer has proven (by accepting a sync from this device, or
  /// by sending one this device accepted) that it also favorited this
  /// device and enabled clipboard sync. Until then the UI shows "waiting
  /// for the other device" and rejected content is not retried.
  final bool clipboardPeerConfirmed;

  /// Same as [clipboardPeerConfirmed], for folder sync.
  final bool folderPeerConfirmed;

  const SyncSettings({
    required this.syncPeerFingerprint,
    required this.clipboardSyncEnabled,
    required this.folderSyncEnabled,
    required this.syncFolderPath,
    required this.clipboardPeerConfirmed,
    required this.folderPeerConfirmed,
  });

  static const empty = SyncSettings(
    syncPeerFingerprint: null,
    clipboardSyncEnabled: false,
    folderSyncEnabled: false,
    syncFolderPath: null,
    clipboardPeerConfirmed: false,
    folderPeerConfirmed: false,
  );

  static const _unset = Object();

  /// Copies with the given fields replaced.
  /// Pass [_unset] (default) to keep a nullable field, or null to clear it.
  SyncSettings copyWith({
    Object? syncPeerFingerprint = _unset,
    bool? clipboardSyncEnabled,
    bool? folderSyncEnabled,
    Object? syncFolderPath = _unset,
    bool? clipboardPeerConfirmed,
    bool? folderPeerConfirmed,
  }) {
    return SyncSettings(
      syncPeerFingerprint: syncPeerFingerprint == _unset ? this.syncPeerFingerprint : syncPeerFingerprint as String?,
      clipboardSyncEnabled: clipboardSyncEnabled ?? this.clipboardSyncEnabled,
      folderSyncEnabled: folderSyncEnabled ?? this.folderSyncEnabled,
      syncFolderPath: syncFolderPath == _unset ? this.syncFolderPath : syncFolderPath as String?,
      clipboardPeerConfirmed: clipboardPeerConfirmed ?? this.clipboardPeerConfirmed,
      folderPeerConfirmed: folderPeerConfirmed ?? this.folderPeerConfirmed,
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

/// File name prefix for clipboard *image* sync transfers. The full name is
/// this prefix + the image extension (e.g. `__clipboard_sync__.png`).
///
/// Unlike text, the image travels as a regular file upload (it is too large
/// for the message preview). The receiver recognizes the prefix + paired
/// sender, writes the image to its clipboard and deletes the transport copy.
const clipboardSyncImagePrefix = '__clipboard_sync__.';

/// Whether [fileName] belongs to a clipboard image sync transfer.
/// The extension check also keeps the clipboard *text* file
/// (`__clipboard_sync__.txt`) from matching.
bool isClipboardSyncImageFileName(String fileName) {
  if (!fileName.startsWith(clipboardSyncImagePrefix)) {
    return false;
  }
  final ext = fileName.substring(clipboardSyncImagePrefix.length).toLowerCase();
  return const {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'}.contains(ext);
}

/// Clipboard images larger than this are not synced.
const maxClipboardImageBytes = 8 * 1024 * 1024;

/// File name used for pairing (PIN) handshake transfers between two
/// devices that want to become sync peers. Like clipboard text sync, the
/// payload travels as the message preview of a single text file; see
/// `pairing_service.dart` for the payload format.
const pairingSyncFileName = '__pairing_sync__.txt';

/// Marker file added to every folder-sync session (a 1-byte dummy that the
/// receiver never saves). It lets the receiver tell an automatic folder
/// sync apart from a manual file send: sync sessions from a device that
/// has not been paired back, or for a feature that is off locally, are
/// declined silently instead of popping up the receive dialog.
const folderSyncMarkerFileName = '__folder_sync__.marker';
