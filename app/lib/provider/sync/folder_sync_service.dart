import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/sync/peer_resolver.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
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
  final DateTime? lastSyncAt;
  final int lastSentCount;
  final int syncedFileCount;
  final String? lastError;

  const FolderSyncState({
    required this.running,
    required this.lastSyncAt,
    required this.lastSentCount,
    required this.syncedFileCount,
    required this.lastError,
  });

  static const initial = FolderSyncState(
    running: false,
    lastSyncAt: null,
    lastSentCount: 0,
    syncedFileCount: 0,
    lastError: null,
  );

  FolderSyncState copyWith({
    bool? running,
    DateTime? lastSyncAt,
    int? lastSentCount,
    int? syncedFileCount,
    String? lastError,
  }) {
    return FolderSyncState(
      running: running ?? this.running,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSentCount: lastSentCount ?? this.lastSentCount,
      syncedFileCount: syncedFileCount ?? this.syncedFileCount,
      lastError: lastError ?? this.lastError,
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
  Future<void> syncNow() => _poll();

  /// Records files that were just received from the peer, so the poller
  /// does not send them back. [relativePaths] use `/` separators.
  void markReceived(List<String> relativePaths) {
    final folderPath = ref.read(syncSettingsProvider).syncFolderPath;
    if (folderPath == null) {
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
    final folderPath = settings.syncFolderPath!;
    final directory = Directory(folderPath);
    if (!directory.existsSync()) {
      _logger.warning('Sync folder does not exist: $folderPath');
      return;
    }

    // Reset baseline when the user picks a different folder.
    if (_lastFolderPath != folderPath) {
      _lastFolderPath = folderPath;
      _lastSynced.clear();
    }

    final peer = resolveSyncPeerOnline(ref);
    if (peer == null) {
      // Peer offline. Keep baseline stale so files sync when it appears.
      return;
    }

    // Scan current folder state.
    final current = <String, _FileSig>{};
    final filesByRel = <String, File>{};
    final settling = <String>{};
    try {
      await for (final entity in directory.list(recursive: true)) {
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
    } catch (e) {
      _logger.warning('Folder scan failed: $e');
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
      await ref.notifier(sendProvider).startSession(target: peer, files: crossFiles, background: true);
      for (final rel in batch) {
        _lastSynced[rel] = current[rel]!;
      }
      final now = DateTime.now();
      state = state.copyWith(lastSyncAt: now, lastSentCount: batch.length, syncedFileCount: _lastSynced.length);
      _logger.info('Folder sync: sent ${batch.length} file(s) to ${peer.alias}');
    } catch (e) {
      _logger.warning('Folder sync send failed: $e');
      state = state.copyWith(lastError: e.toString());
    } finally {
      _sending = false;
    }
  }
}
