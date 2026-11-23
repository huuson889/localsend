import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/sync_settings.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/sync/peer_resolver.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/ui/sync_toast.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/metadata.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('FolderSync');

/// Poll interval for folder changes.
const _pollInterval = Duration(seconds: 3);

/// Max files per sync session. Remaining changes are sent on the next poll.
const _maxBatchSize = 100;

/// Files modified more recently than this are considered still being written
/// and are skipped until they settle.
const _settleDelay = Duration(seconds: 1);

/// How a background sync send ended; see [FolderSyncService._sendInBackground].
enum _SendOutcome { sent, rejected, failed }

class FolderSyncState {
  final bool running;

  /// When the poller last scanned the folder (only while sync is active).
  /// Lets the UI prove the automatic loop is alive.
  final DateTime? lastPollAt;
  final DateTime? lastSyncAt;
  final int lastSentCount;
  final int syncedFileCount;
  final String? lastError;

  const FolderSyncState({
    required this.running,
    required this.lastPollAt,
    required this.lastSyncAt,
    required this.lastSentCount,
    required this.syncedFileCount,
    required this.lastError,
  });

  static const initial = FolderSyncState(
    running: false,
    lastPollAt: null,
    lastSyncAt: null,
    lastSentCount: 0,
    syncedFileCount: 0,
    lastError: null,
  );

  FolderSyncState copyWith({
    bool? running,
    DateTime? lastPollAt,
    DateTime? lastSyncAt,
    int? lastSentCount,
    int? syncedFileCount,
    String? lastError,
    bool clearError = false,
  }) {
    return FolderSyncState(
      running: running ?? this.running,
      lastPollAt: lastPollAt ?? this.lastPollAt,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSentCount: lastSentCount ?? this.lastSentCount,
      syncedFileCount: syncedFileCount ?? this.syncedFileCount,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

final folderSyncProvider = NotifierProvider<FolderSyncService, FolderSyncState>((ref) {
  return FolderSyncService();
});

/// Per-peer transient-failure bookkeeping. Peers are independent: one
/// peer failing (or being offline) must not block, delay or spam-report
/// sync with the others.
class _PeerRetryState {
  int consecutiveFailures = 0;
  DateTime? nextRetryAt;
  bool failureToastShown = false;
}

/// Signature of a synced file, used to detect changes and prevent echo loops.
///
/// Each side records the signature of files it sent or received. When the
/// poller sees a file whose signature matches the recorded one, it is
/// skipped — so a file received from the peer is never sent back.
///
/// Limitation: change detection is size + mtime based (no content hash).
/// A same-size edit within the same mtime tick may be missed. Deletions are
/// not propagated (only creations/updates sync). If both sides edit the same
/// file concurrently, last write wins.
class _FileSig {
  final int size;
  final int modifiedMillis;

  const _FileSig(this.size, this.modifiedMillis);

  @override
  bool operator ==(Object other) => other is _FileSig && other.size == size && other.modifiedMillis == modifiedMillis;

  @override
  int get hashCode => Object.hash(size, modifiedMillis);
}

/// A file found by scanning an Android SAF directory tree.
class _SafFile {
  final String uri;
  final int size;
  final String? lastModifiedRfc3339;

  const _SafFile({
    required this.uri,
    required this.size,
    required this.lastModifiedRfc3339,
  });
}

/// Keeps a shared folder in sync with the paired device (both directions).
///
/// - Polls the folder every few seconds, sends new/changed files to the peer
///   via the normal file transfer (`background: true`, no dialogs).
/// - The receiver saves incoming sync files straight into its sync folder
///   and auto-accepts them (see `ReceiveController`).
/// - [markReceived] is called by the receiver after a sync session finishes
///   so received files are not echoed back.
class FolderSyncService extends Notifier<FolderSyncState> {
  Timer? _timer;
  bool _sending = false;

  /// Last synced state per `peer|folder` baseline key:
  /// relative path -> signature of last synced state.
  final Map<String, Map<String, _FileSig>> _lastSyncedByKey = {};

  /// Baseline keys whose baseline has been recorded (loaded from storage
  /// or captured by a first scan). The first scan for a new key only
  /// records the baseline (existing files are *not* sent), so setting
  /// sync up never blasts the folder's current content at a peer. Only
  /// later changes are synced.
  final Set<String> _initializedBaselines = {};

  /// Set by [syncNow]: the next poll sends the folder's current content
  /// once, explicitly, instead of only recording the baseline.
  bool _forceSendExisting = false;

  /// Signature of the change set each peer last rejected (not paired
  /// back / feature off there), by peer fingerprint. The same set is not
  /// offered to that peer again; a new change (or the manual sync
  /// button) retries. Other peers are unaffected.
  final Map<String, String> _rejectedChangeSignatureByPeer = {};

  /// Transient send failures are retried silently with a growing delay;
  /// the user only gets one failure toast per failure streak and peer,
  /// not one per poll.
  final Map<String, _PeerRetryState> _retryByPeer = {};

  _PeerRetryState _retryFor(String fingerprint) => _retryByPeer.putIfAbsent(fingerprint, () => _PeerRetryState());

  bool _retryPending(String fingerprint, DateTime now) {
    final retry = _retryFor(fingerprint);
    return retry.nextRetryAt != null && now.isBefore(retry.nextRetryAt!);
  }

  void _noteSendFailure(String fingerprint) {
    final retry = _retryFor(fingerprint);
    retry.consecutiveFailures++;
    final delaySeconds = retry.consecutiveFailures <= 1 ? 5 : retry.consecutiveFailures == 2 ? 15 : 30;
    retry.nextRetryAt = DateTime.now().add(Duration(seconds: delaySeconds));
  }

  /// Whether a failure toast should be shown now (once per streak).
  bool _claimFailureToast(String fingerprint) {
    final retry = _retryFor(fingerprint);
    if (retry.failureToastShown) {
      return false;
    }
    retry.failureToastShown = true;
    return true;
  }

  void _noteSendSuccess(String fingerprint) {
    final retry = _retryFor(fingerprint);
    retry.consecutiveFailures = 0;
    retry.nextRetryAt = null;
    retry.failureToastShown = false;
  }

  String _baselineKey(String fingerprint, String folderPath) => '$fingerprint|$folderPath';

  @override
  FolderSyncState init() => FolderSyncState.initial;

  void start() {
    if (_timer != null) {
      return;
    }
    _logger.info('Folder sync started');
    state = state.copyWith(running: true);
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _logger.info('Folder sync stopped');
    state = state.copyWith(running: false);
  }

  /// Forces an immediate poll (used by the "Sync now" button).
  /// Unlike the automatic polls, this sends the folder's current content
  /// even if it predates the setup: the user asked for it explicitly.
  Future<void> syncNow() async {
    start();
    _forceSendExisting = true;
    _rejectedChangeSignatureByPeer.clear();
    await _poll();
  }

  /// Polls once immediately. Used when the app returns to the foreground or
  /// right after sync was enabled, so changes made in the meantime are
  /// picked up without waiting for the next tick. Also revives the periodic
  /// timer in case this provider was recreated.
  Future<void> pollNow() async {
    start();
    await _poll();
  }

  /// Sends [files] in a background session and reports how it ended.
  /// `startSession` also returns normally when the peer declines or cannot
  /// be reached, so the sync bookkeeping must not treat every return as
  /// success — otherwise a failed folder sync would be marked as done and
  /// never retried. A *rejected* send means the peer has not agreed to
  /// folder sync (not paired back / feature off there): the same change
  /// set must not be offered again on every poll.
  Future<_SendOutcome> _sendInBackground({required Device peer, required List<CrossFile> files}) async {
    final beforeSessionIds = ref.read(sendProvider).keys.toSet();
    await ref.notifier(sendProvider).startSession(target: peer, files: files, background: true);
    final remaining = ref
        .read(sendProvider)
        .values
        .where((s) => !beforeSessionIds.contains(s.sessionId) && s.target.fingerprint == peer.fingerprint)
        .toList();
    if (remaining.isEmpty) {
      // Successful background sessions close (and remove) themselves.
      return _SendOutcome.sent;
    }
    const rejectedStates = {
      SessionStatus.declined,
      SessionStatus.tooManyAttempts,
      SessionStatus.canceledByReceiver,
    };
    if (remaining.any((s) => rejectedStates.contains(s.status))) {
      return _SendOutcome.rejected;
    }
    return _SendOutcome.failed;
  }

  /// Loads the persisted baseline for [baselineKey] into memory. A
  /// missing entry means this peer+folder was never set up: the key stays
  /// out of [_initializedBaselines] so the first scan only records the
  /// baseline instead of sending the folder's existing content.
  void _ensureBaselineLoaded(String baselineKey) {
    if (_lastSyncedByKey.containsKey(baselineKey)) {
      return;
    }
    final map = <String, _FileSig>{};
    final stored = ref.read(persistenceProvider).getFolderSyncSignatures()[baselineKey];
    if (stored != null) {
      for (final entry in stored.entries) {
        if (entry.value.length >= 2) {
          map[entry.key] = _FileSig(entry.value[0], entry.value[1]);
        }
      }
      _initializedBaselines.add(baselineKey);
    }
    _lastSyncedByKey[baselineKey] = map;
  }

  /// Persists the in-memory baseline so restarts keep detecting changes
  /// made while the app was closed.
  Future<void> _saveBaseline(String baselineKey) async {
    final map = _lastSyncedByKey[baselineKey];
    if (map == null) {
      return;
    }
    final persistence = ref.read(persistenceProvider);
    final all = persistence.getFolderSyncSignatures();
    all[baselineKey] = {for (final entry in map.entries) entry.key: [entry.value.size, entry.value.modifiedMillis]};
    await persistence.setFolderSyncSignatures(all);
  }

  /// Records files that were just received from a peer, so the poller
  /// does not send them back. [relativePaths] use `/` separators.
  ///
  /// The received signatures are recorded in *every* paired peer's
  /// baseline, not just the sender's: pairs are independent, so a file
  /// received from one peer must not be forwarded to another peer. It
  /// only syncs onward if the user actually modifies it locally.
  Future<void> markReceived(List<String> relativePaths) async {
    final settings = ref.read(syncSettingsProvider);
    final folderPath = settings.syncFolderPath;
    if (folderPath == null) {
      return;
    }
    final received = <String, _FileSig>{};
    if (folderPath.startsWith('content://')) {
      // Android SAF folder: stat the saved files through the tree listing
      // (dart:io cannot address content URIs).
      try {
        final byRelativePath = {
          for (final file in await android_channel.listDirectoryFilesAndroid(folderPath)) file.relativePath: file,
        };
        for (final rel in relativePaths) {
          final file = byRelativePath[rel];
          if (file != null) {
            received[rel] = _FileSig(file.size, file.lastModifiedMillis ?? 0);
          }
        }
      } catch (e) {
        _logger.fine('markReceived (SAF) failed: $e');
      }
    } else {
      for (final rel in relativePaths) {
        try {
          final file = File(p.join(folderPath, rel));
          if (!file.existsSync()) {
            continue;
          }
          final stat = file.statSync();
          received[rel] = _FileSig(stat.size, stat.modified.millisecondsSinceEpoch);
        } catch (e) {
          _logger.fine('markReceived failed for $rel: $e');
        }
      }
    }
    if (received.isEmpty) {
      return;
    }
    for (final fingerprint in settings.syncPeerFingerprints) {
      final key = _baselineKey(fingerprint, folderPath);
      _ensureBaselineLoaded(key);
      if (!_initializedBaselines.contains(key)) {
        // This peer has no baseline yet: its first scan will record the
        // folder (including the just-received files) as its baseline.
        continue;
      }
      _lastSyncedByKey[key]!.addAll(received);
      await _saveBaseline(key);
    }
    var count = 0;
    for (final map in _lastSyncedByKey.values) {
      if (map.length > count) {
        count = map.length;
      }
    }
    state = state.copyWith(syncedFileCount: count);
  }

  Future<void> _poll() async {
    if (_sending) {
      return;
    }
    final settings = ref.read(syncSettingsProvider);
    if (!settings.folderSyncActive) {
      return;
    }
    state = state.copyWith(lastPollAt: DateTime.now());
    final folderPath = settings.syncFolderPath!;
    // On Android the picked folder is a SAF `content://` tree URI, which
    // dart:io cannot list or stat; it is scanned through the platform
    // channel instead (see the scan below).
    final isSafFolder = folderPath.startsWith('content://');
    final directory = isSafFolder ? null : Directory(folderPath);
    if (directory != null && !directory.existsSync()) {
      _logger.warning('Sync folder does not exist: $folderPath');
      state = state.copyWith(lastError: 'Sync folder does not exist');
      return;
    }

    // Scan current folder state (once, shared by all peers).
    final current = <String, _FileSig>{};
    final filesByRel = <String, File>{};
    final safFilesByRel = <String, _SafFile>{};
    final settling = <String>{};
    try {
      if (isSafFolder) {
        for (final file in await android_channel.listDirectoryFilesAndroid(folderPath)) {
          final rel = file.relativePath;
          final signature = _FileSig(file.size, file.lastModifiedMillis ?? 0);
          current[rel] = signature;
          safFilesByRel[rel] = _SafFile(
            uri: file.uri,
            size: file.size,
            lastModifiedRfc3339: file.lastModifiedRfc3339,
          );
          final modifiedMillis = file.lastModifiedMillis;
          if (modifiedMillis != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(modifiedMillis)) < _settleDelay) {
            settling.add(rel);
          }
        }
      } else {
        await for (final entity in directory!.list(recursive: true)) {
          if (entity is! File) {
            continue;
          }
          final rel = p.relative(entity.path, from: folderPath).replaceAll('\\', '/');
          try {
            final stat = entity.statSync();
            current[rel] = _FileSig(stat.size, stat.modified.millisecondsSinceEpoch);
            filesByRel[rel] = entity;
            // Files modified very recently are likely still being written:
            // defer sending them until they settle, but keep them in
            // [current] so their baseline entry is not dropped (which
            // would cause an echo of just-received files).
            if (DateTime.now().difference(stat.modified) < _settleDelay) {
              settling.add(rel);
            }
          } catch (e) {
            _logger.fine('Skipping unreadable file $rel: $e');
          }
        }
      }
    } catch (e) {
      _logger.warning('Folder scan failed: $e');
      state = state.copyWith(lastError: e.toString());
      return;
    }

    final forceSendExisting = _forceSendExisting;

    // Per-peer baselines: the first scan for a peer+folder only records
    // what already exists and sends nothing (unless the user pressed
    // "Sync now"). Sync covers changes made after setup.
    for (final fingerprint in settings.syncPeerFingerprints) {
      final key = _baselineKey(fingerprint, folderPath);
      _ensureBaselineLoaded(key);
      if (!_initializedBaselines.contains(key)) {
        if (!forceSendExisting) {
          _lastSyncedByKey[key]!
            ..clear()
            ..addAll(current);
          _initializedBaselines.add(key);
          await _saveBaseline(key);
        }
      } else {
        // Drop baseline entries for locally deleted files (deletion
        // itself is not propagated, but a later re-creation must be
        // detected as a change).
        _lastSyncedByKey[key]!.removeWhere((rel, _) => !current.containsKey(rel));
      }
    }
    state = state.copyWith(syncedFileCount: current.length);

    final onlinePeers = resolveSyncPeers(ref);
    if (onlinePeers.isEmpty) {
      // All peers offline: wait silently. Baselines stay stale, so
      // changed files are picked up when a peer appears again. A pending
      // manual force-send stays pending for the same reason.
      return;
    }
    _forceSendExisting = false;

    Future<List<CrossFile>> buildFiles(List<String> batch) async {
      // The marker identifies this session as an automatic folder sync
      // to the receiver (never saved there). Without it, the files would
      // be indistinguishable from a manual send.
      final crossFiles = <CrossFile>[
        CrossFile(
          name: folderSyncMarkerFileName,
          fileType: folderSyncMarkerFileName.guessFileType(),
          size: 1,
          thumbnail: null,
          asset: null,
          path: null,
          bytes: const [1],
          lastModified: null,
          lastAccessed: null,
        ),
      ];
      for (final rel in batch) {
        final safFile = safFilesByRel[rel];
        if (safFile != null) {
          // SAF files are read through their content URI by the upload
          // task; their timestamps come from the directory listing (no
          // stat in Rust).
          crossFiles.add(
            CrossFile(
              name: rel,
              fileType: rel.guessFileType(),
              size: safFile.size,
              thumbnail: null,
              asset: null,
              path: safFile.uri,
              bytes: null,
              lastModified: safFile.lastModifiedRfc3339,
              lastAccessed: null,
            ),
          );
          continue;
        }
        final file = filesByRel[rel]!;
        final metadata = await readFileMetadata(path: file.path);
        crossFiles.add(
          CrossFile(
            name: rel,
            fileType: rel.guessFileType(),
            size: file.lengthSync(),
            thumbnail: null,
            asset: null,
            path: file.path,
            bytes: null,
            lastModified: metadata?.modified,
            lastAccessed: metadata?.accessed,
          ),
        );
      }
      return crossFiles;
    }

    _sending = true;
    try {
      // Fan out peer by peer. Each peer has its own baseline, rejected
      // change set and retry backoff: one peer failing, rejecting or
      // being slow never affects the others.
      for (final peer in onlinePeers) {
        final fingerprint = peer.fingerprint;
        final key = _baselineKey(fingerprint, folderPath);
        final baseline = _lastSyncedByKey[key]!;
        final changed = forceSendExisting
            ? current.keys.where((rel) => !settling.contains(rel)).toList()
            : current.entries.where((e) => baseline[e.key] != e.value && !settling.contains(e.key)).map((e) => e.key).toList();
        changed.sort();
        if (changed.isEmpty) {
          continue;
        }

        // Anti-spam per peer: if this peer already rejected exactly this
        // change set (it has not agreed to folder sync), do not offer it
        // again. Any new or further-changed file retries.
        final changeSignature = changed.map((rel) => '$rel:${current[rel]!.size}:${current[rel]!.modifiedMillis}').join('|');
        if (changeSignature == _rejectedChangeSignatureByPeer[fingerprint]) {
          continue;
        }
        if (_retryPending(fingerprint, DateTime.now())) {
          // A recent send to this peer failed; retry after the backoff.
          continue;
        }

        final batch = changed.take(_maxBatchSize).toList();
        try {
          final crossFiles = await buildFiles(batch);
          showSyncToastLocalized(
            en: 'Sending ${batch.length} folder file(s) to ${peer.alias}…',
            vi: 'Đang gửi ${batch.length} file thư mục tới ${peer.alias}…',
          );
          final outcome = await _sendInBackground(peer: peer, files: crossFiles);
          if (outcome == _SendOutcome.rejected) {
            // This peer has not agreed to folder sync (yet): remember
            // this change set for this peer only.
            _rejectedChangeSignatureByPeer[fingerprint] = changeSignature;
            await ref.notifier(syncSettingsProvider).setFolderPeerConfirmed(fingerprint, false);
            state = state.copyWith(lastError: 'Waiting for ${peer.alias} to favorite this device and enable folder sync');
            showSyncToastLocalized(
              en: 'Waiting for ${peer.alias} to enable folder sync',
              vi: 'Đang chờ ${peer.alias} bật đồng bộ thư mục',
            );
          } else if (outcome == _SendOutcome.failed) {
            // Transient failure: keep this peer's baseline stale so a
            // later poll retries, silently and with backoff.
            _noteSendFailure(fingerprint);
            state = state.copyWith(lastError: 'Folder files were not accepted by ${peer.alias}');
            if (_claimFailureToast(fingerprint)) {
              showSyncToastLocalized(en: 'Folder sync failed', vi: 'Đồng bộ thư mục thất bại');
            }
          } else {
            _noteSendSuccess(fingerprint);
            _rejectedChangeSignatureByPeer.remove(fingerprint);
            for (final rel in batch) {
              baseline[rel] = current[rel]!;
            }
            _initializedBaselines.add(key);
            await _saveBaseline(key);
            await ref.notifier(syncSettingsProvider).setFolderPeerConfirmed(fingerprint, true);
            state = state.copyWith(
              lastSyncAt: DateTime.now(),
              lastSentCount: batch.length,
              syncedFileCount: current.length,
              clearError: true,
            );
            showSyncToastLocalized(
              en: 'Sent ${batch.length} folder file(s) to ${peer.alias}',
              vi: 'Đã gửi ${batch.length} file thư mục tới ${peer.alias}',
            );
            _logger.info('Folder sync: sent ${batch.length} file(s) to ${peer.alias}');
          }
        } catch (e) {
          _logger.warning('Folder sync send to ${peer.alias} failed: $e');
          _noteSendFailure(fingerprint);
          state = state.copyWith(lastError: e.toString());
          if (_claimFailureToast(fingerprint)) {
            showSyncToastLocalized(en: 'Folder sync failed', vi: 'Đồng bộ thư mục thất bại');
          }
        }
      }
    } finally {
      _sending = false;
    }
  }
}
