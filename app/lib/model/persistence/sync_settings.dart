/// Settings for paired-device sync (clipboard + shared folder).
///
/// The "paired" devices are [FavoriteDevice]s that completed PIN pairing
/// with this device. Trust comes from the existing fingerprint pinning
/// (mTLS) and favorites: sync only ever talks to these peers, never
/// broadcasts.
///
/// Pairing is multi-device but strictly pairwise: this device can be
/// paired with several devices, and each pair syncs independently. Content
/// received from one peer is not forwarded to another peer; two peers only
/// sync with each other when they are paired with each other directly.
///
/// This is intentionally a plain model (not dart_mappable) so it can live
/// outside [SettingsState] without regenerating mappers.
class SyncSettings {
  /// Fingerprints of the paired (trusted) devices. Empty if none paired.
  final List<String> syncPeerFingerprints;

  /// Automatically sync clipboard text to/from the paired devices on copy.
  final bool clipboardSyncEnabled;

  /// Automatically sync new/changed files in [syncFolderPath] both ways.
  final bool folderSyncEnabled;

  /// Local folder that is kept in sync with the paired devices.
  final String? syncFolderPath;

  /// Peers that have proven (by accepting a sync from this device, or by
  /// sending one this device accepted) that they also paired this device
  /// and enabled clipboard sync. Until a peer is in this set, the UI shows
  /// it as "waiting for the other device" and rejected content is not
  /// retried for that peer.
  final Set<String> clipboardConfirmedPeerFingerprints;

  /// Same as [clipboardConfirmedPeerFingerprints], for folder sync.
  final Set<String> folderConfirmedPeerFingerprints;

  const SyncSettings({
    required this.syncPeerFingerprints,
    required this.clipboardSyncEnabled,
    required this.folderSyncEnabled,
    required this.syncFolderPath,
    required this.clipboardConfirmedPeerFingerprints,
    required this.folderConfirmedPeerFingerprints,
  });

  static const empty = SyncSettings(
    syncPeerFingerprints: [],
    clipboardSyncEnabled: false,
    folderSyncEnabled: false,
    syncFolderPath: null,
    clipboardConfirmedPeerFingerprints: {},
    folderConfirmedPeerFingerprints: {},
  );

  static const _unset = Object();

  /// Copies with the given fields replaced.
  /// Pass [_unset] (default) to keep a nullable field, or null to clear it.
  SyncSettings copyWith({
    List<String>? syncPeerFingerprints,
    bool? clipboardSyncEnabled,
    bool? folderSyncEnabled,
    Object? syncFolderPath = _unset,
    Set<String>? clipboardConfirmedPeerFingerprints,
    Set<String>? folderConfirmedPeerFingerprints,
  }) {
    return SyncSettings(
      syncPeerFingerprints: syncPeerFingerprints ?? this.syncPeerFingerprints,
      clipboardSyncEnabled: clipboardSyncEnabled ?? this.clipboardSyncEnabled,
      folderSyncEnabled: folderSyncEnabled ?? this.folderSyncEnabled,
      syncFolderPath: syncFolderPath == _unset ? this.syncFolderPath : syncFolderPath as String?,
      clipboardConfirmedPeerFingerprints: clipboardConfirmedPeerFingerprints ?? this.clipboardConfirmedPeerFingerprints,
      folderConfirmedPeerFingerprints: folderConfirmedPeerFingerprints ?? this.folderConfirmedPeerFingerprints,
    );
  }

  bool get hasSyncPeer => syncPeerFingerprints.isNotEmpty;

  bool isSyncPeer(String fingerprint) => syncPeerFingerprints.contains(fingerprint);

  bool isClipboardPeerConfirmed(String fingerprint) => clipboardConfirmedPeerFingerprints.contains(fingerprint);

  bool isFolderPeerConfirmed(String fingerprint) => folderConfirmedPeerFingerprints.contains(fingerprint);

  /// Whether every paired peer has confirmed clipboard sync. False when
  /// there are no peers (nothing can be "active" yet).
  bool get clipboardAllPeersConfirmed =>
      syncPeerFingerprints.isNotEmpty && syncPeerFingerprints.every(clipboardConfirmedPeerFingerprints.contains);

  /// Whether every paired peer has confirmed folder sync.
  bool get folderAllPeersConfirmed =>
      syncPeerFingerprints.isNotEmpty && syncPeerFingerprints.every(folderConfirmedPeerFingerprints.contains);

  int get clipboardConfirmedCount => syncPeerFingerprints.where(clipboardConfirmedPeerFingerprints.contains).length;

  int get folderConfirmedCount => syncPeerFingerprints.where(folderConfirmedPeerFingerprints.contains).length;

  /// Whether clipboard sync can run (at least one peer + enabled).
  bool get clipboardSyncActive => clipboardSyncEnabled && hasSyncPeer;

  /// Whether folder sync can run (peer + folder selected + enabled).
  bool get folderSyncActive => folderSyncEnabled && hasSyncPeer && syncFolderPath != null;
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
