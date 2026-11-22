import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/sync_settings.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/sync/peer_resolver.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('ClipboardSync');

/// Poll interval for clipboard changes.
const _pollInterval = Duration(milliseconds: 1000);

/// Minimum time between two outgoing syncs (rate limit).
const _minSendInterval = Duration(milliseconds: 1500);

class ClipboardSyncState {
  final bool running;

  /// When the poller last checked the clipboard (only while sync is active).
  /// Lets the UI prove the automatic loop is alive.
  final DateTime? lastPollAt;
  final DateTime? lastSentAt;
  final DateTime? lastReceivedAt;
  final String? lastError;

  const ClipboardSyncState({
    required this.running,
    required this.lastPollAt,
    required this.lastSentAt,
    required this.lastReceivedAt,
    required this.lastError,
  });

  static const initial = ClipboardSyncState(
    running: false,
    lastPollAt: null,
    lastSentAt: null,
    lastReceivedAt: null,
    lastError: null,
  );

  ClipboardSyncState copyWith({
    bool? running,
    DateTime? lastPollAt,
    DateTime? lastSentAt,
    DateTime? lastReceivedAt,
    String? lastError,
    bool clearError = false,
  }) {
    return ClipboardSyncState(
      running: running ?? this.running,
      lastPollAt: lastPollAt ?? this.lastPollAt,
      lastSentAt: lastSentAt ?? this.lastSentAt,
      lastReceivedAt: lastReceivedAt ?? this.lastReceivedAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

final clipboardSyncProvider = NotifierProvider<ClipboardSyncService, ClipboardSyncState>((ref) {
  return ClipboardSyncService();
});

/// Watches the local clipboard and forwards new text to the paired device.
///
/// How it works:
/// - Polls [Clipboard.getData] every second (there is no cross-platform
///   clipboard-change callback in Flutter).
/// - A changed, non-empty text (<= [maxClipboardSyncBytes]) is sent as a
///   single text file named [clipboardSyncFileName] via the normal
///   `prepare-upload` flow with `background: true`. The receiver applies it
///   to its clipboard without any dialog (see `ReceiveController`).
/// - Loop prevention: [markReceived] records the last received text so the
///   poller does not echo it back.
///
/// Platform notes:
/// - Desktop (Windows/macOS/Linux): works while the app runs, even minimized
///   to tray.
/// - Android/iOS: the OS restricts background clipboard reads (Android 10+,
///   iOS 16+ paste prompt). Sync effectively happens while the app is in the
///   foreground. Failures are logged and ignored.
class ClipboardSyncService extends Notifier<ClipboardSyncState> {
  Timer? _timer;
  bool _sending = false;

  /// Last clipboard text seen by the poller.
  String? _lastKnownText;

  /// Last text that was sent to or received from the peer.
  /// Used to suppress echo loops.
  String? _lastSyncedText;

  DateTime? _lastSendAt;

  @override
  ClipboardSyncState init() => ClipboardSyncState.initial;

  void start() {
    if (_timer != null) {
      return;
    }
    _logger.info('Clipboard sync started');
    state = state.copyWith(running: true);
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _logger.info('Clipboard sync stopped');
    state = state.copyWith(running: false);
  }

  /// Forces an immediate poll (used by the "Send clipboard now" button).
  /// Clears the caches so the current clipboard is sent even if it was
  /// already seen/synced.
  Future<void> syncNow() async {
    start();
    _lastKnownText = null;
    _lastSyncedText = null;
    await _poll();
  }

  /// Polls once immediately without clearing the caches. Used when the app
  /// returns to the foreground or right after sync was enabled, so changes
  /// made in the meantime are picked up without waiting for the next tick.
  /// Also revives the periodic timer in case this provider was recreated.
  Future<void> pollNow() async {
    start();
    await _poll();
  }

  /// Forgets the cached clipboard texts so the next poll treats the current
  /// clipboard as new. Used after the peer changed or sync was (re-)enabled:
  /// the current clipboard should be pushed to the (new) peer once.
  void resetSyncCache() {
    _lastKnownText = null;
    _lastSyncedText = null;
  }

  /// Called by the receiver when clipboard text was applied from the peer,
  /// so the poller does not send it back.
  void markReceived(String text) {
    _lastSyncedText = text;
    _lastKnownText = text;
    state = state.copyWith(lastReceivedAt: DateTime.now());
  }

  Future<void> _poll() async {
    if (_sending) {
      return;
    }
    final settings = ref.read(syncSettingsProvider);
    if (!settings.clipboardSyncActive) {
      return;
    }
    state = state.copyWith(lastPollAt: DateTime.now());

    String? current;
    try {
      current = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (e) {
      // No clipboard access (e.g. background on mobile). Retry next tick.
      _logger.fine('Clipboard read failed: $e');
      return;
    }

    if (current == null || current.isEmpty) {
      _lastKnownText = current;
      return;
    }
    if (current == _lastSyncedText) {
      // Already synced (sent or received). Just track it.
      _lastKnownText = current;
      return;
    }
    if (current == _lastKnownText) {
      // Unchanged since last poll.
      return;
    }

    final bytes = utf8.encode(current);
    if (bytes.length > maxClipboardSyncBytes) {
      _logger.info('Clipboard text too large (${bytes.length} bytes), skipped');
      _lastKnownText = current;
      return;
    }

    final now = DateTime.now();
    if (_lastSendAt != null && now.difference(_lastSendAt!) < _minSendInterval) {
      // Rate limited. Keep _lastKnownText stale so we retry next tick.
      return;
    }

    final peer = resolveSyncPeer(ref);
    if (peer == null) {
      // Peer offline. Keep _lastKnownText stale so we retry when it appears.
      return;
    }

    _sending = true;
    try {
      final file = CrossFile(
        name: clipboardSyncFileName,
        fileType: FileType.text,
        size: bytes.length,
        thumbnail: null,
        asset: null,
        path: null,
        bytes: bytes,
        lastModified: null,
        lastAccessed: null,
      );
      await ref.notifier(sendProvider).startSession(target: peer, files: [file], background: true);
      _lastSyncedText = current;
      _lastKnownText = current;
      _lastSendAt = now;
      state = state.copyWith(lastSentAt: now, clearError: true);
      _logger.info('Clipboard synced to ${peer.alias} (${bytes.length} bytes)');
    } catch (e) {
      _logger.warning('Clipboard sync send failed: $e');
      state = state.copyWith(lastError: e.toString());
    } finally {
      _sending = false;
    }
  }
}
