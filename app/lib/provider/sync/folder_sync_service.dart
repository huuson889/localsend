import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
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

  /// Relative path -> signature of last synced state.
  final Map<String, _FileSig> _lastSynced = {};

  String? _lastFolderPath;

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
  Future<void> syncNow() async {
    start();
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

  /// Sends [files] in a background session and reports whether the transfer
  /// was actually accepted and finished. `startSession` also returns
  /// normally when the peer is busy, declines or cannot be reached, so the
  /// sync bookkeeping must not treat every return as success — otherwise a
  /// failed folder sync would be marked as done and never retried.
  Future<bool> _sendInBackground({required Device peer, required List<CrossFile> files}) async {
    final beforeSessionIds = ref.read(sendProvider).keys.toSet();
    await ref.notifier(sendProvider).startSession(target: peer, files: files, background: true);
    final remaining = ref
        .read(sendProvider)
        .values
        .where((s) => !beforeSessionIds.contains(s.sessionId) && s.target.fingerprint == peer.fingerprint)
        .toList();
    if (remaining.isEmpty) {
      // Successful background sessions close (and remove) themselves.
      return true;
    }
    const failureStates = {
      SessionStatus.finishedWithErrors,
      SessionStatus.declined,
      SessionStatus.recipientBusy,
      SessionStatus.tooManyAttempts,
      SessionStatus.canceledBySender,
      SessionStatus.canceledByReceiver,
    };
    return !remaining.any((s) => failureStates.contains(s.status));
  }

  /// Records files that were just received from the peer, so the poller
  /// does not send them back. [relativePaths] use `/` separators.
  Future<void> markReceived(List<String> relativePaths) async {
    final folderPath = ref.read(syncSettingsProvider).syncFolderPath;
    if (folderPath == null) {
      return;
    }
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
            _lastSynced[rel] = _FileSig(file.size, file.lastModifiedMillis ?? 0);
          }
        }
      } catch (e) {
        _logger.fine('markReceived (SAF) failed: $e');
      }
      state = state.copyWith(syncedFileCount: _lastSynced.length);
      return;
    }
    for (final rel in relativePaths) {
      try {
        final file = File(p.join(folderPath, rel));
        if (!file.existsSync()) {
          continue;
        }
        final stat = file.statSync();
        _lastSynced[rel] = _FileSig(stat.size, stat.modified.millisecondsSinceEpoch);
      } catch (e) {
        _logger.fine('markReceived failed for $rel: $e');
      }
    }
    state = state.copyWith(syncedFileCount: _lastSynced.length);
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

    // Reset baseline when the user picks a different folder.
    if (_lastFolderPath != folderPath) {
      _lastFolderPath = folderPath;
      _lastSynced.clear();
    }

    final peer = resolveSyncPeer(ref);
    if (peer == null) {
      // Peer offline. Keep baseline stale so files sync when it appears.
      return;
    }

    // Scan current folder state.
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
            // defer sending them until they settle, but keep them in [current]
            // so their baseline entry is not dropped (which would cause an
            // echo of just-received files).
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

    // Drop baseline entries for locally deleted files (deletion itself is
    // not propagated, but a later re-creation must be detected).
    _lastSynced.removeWhere((rel, _) => !current.containsKey(rel));

    final changed = current.entries.where((e) => _lastSynced[e.key] != e.value && !settling.contains(e.key)).map((e) => e.key).toList()..sort();
    if (changed.isEmpty) {
      return;
    }

    final batch = changed.take(_maxBatchSize).toList();
    _sending = true;
    try {
      final crossFiles = <CrossFile>[];
      for (final rel in batch) {
        final safFile = safFilesByRel[rel];
        if (safFile != null) {
          // SAF files are read through their content URI by the upload task;
          // their timestamps come from the directory listing (no stat in Rust).
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
      showSyncToastLocalized(
        en: 'Sending ${batch.length} folder file(s) to ${peer.alias}…',
        vi: 'Đang gửi ${batch.length} file thư mục tới ${peer.alias}…',
      );
      final sent = await _sendInBackground(peer: peer, files: crossFiles);
      if (!sent) {
        // Keep the baseline stale so the next poll retries these files.
        state = state.copyWith(lastError: 'Folder files were not accepted by ${peer.alias}');
        showSyncToastLocalized(en: 'Folder sync failed', vi: 'Đồng bộ thư mục thất bại');
        return;
      }
      for (final rel in batch) {
        _lastSynced[rel] = current[rel]!;
      }
      final now = DateTime.now();
      state = state.copyWith(
        lastSyncAt: now,
        lastSentCount: batch.length,
        syncedFileCount: _lastSynced.length,
        clearError: true,
      );
      showSyncToastLocalized(
        en: 'Sent ${batch.length} folder file(s) to ${peer.alias}',
        vi: 'Đã gửi ${batch.length} file thư mục tới ${peer.alias}',
      );
      _logger.info('Folder sync: sent ${batch.length} file(s) to ${peer.alias}');
    } catch (e) {
      _logger.warning('Folder sync send failed: $e');
      state = state.copyWith(lastError: e.toString());
      showSyncToastLocalized(en: 'Folder sync failed', vi: 'Đồng bộ thư mục thất bại');
    } finally {
      _sending = false;
    }
  }
}
