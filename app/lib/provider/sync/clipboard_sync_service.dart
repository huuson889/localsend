import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/sync_settings.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/sync/peer_resolver.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/determine_image_type.dart';
import 'package:localsend_app/util/image_converter.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/sync_toast.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('ClipboardSync');

/// Poll interval for clipboard changes.
const _pollInterval = Duration(milliseconds: 1000);

/// Minimum time between two outgoing syncs (rate limit).
const _minSendInterval = Duration(milliseconds: 1500);

/// How a background sync send ended; see [ClipboardSyncService._sendInBackground].
enum _SendOutcome { sent, rejected, failed }

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

  /// Signature of the last clipboard image seen by the poller.
  String? _lastKnownImageSig;

  /// Signature of the last image that was sent to or received from the peer.
  /// Used to suppress echo loops.
  String? _lastSyncedImageSig;

  DateTime? _lastSendAt;

  /// Transient send failures are retried silently with a growing delay;
  /// the user only gets one failure toast per failure streak, not one
  /// per poll.
  int _consecutiveSendFailures = 0;
  DateTime? _nextRetryAt;
  bool _failureToastShown = false;

  @override
  ClipboardSyncState init() => ClipboardSyncState.initial;

  bool _retryPending(DateTime now) => _nextRetryAt != null && now.isBefore(_nextRetryAt!);

  void _noteSendFailure() {
    _consecutiveSendFailures++;
    final delaySeconds = _consecutiveSendFailures <= 1 ? 5 : _consecutiveSendFailures == 2 ? 15 : 30;
    _nextRetryAt = DateTime.now().add(Duration(seconds: delaySeconds));
  }

  /// Whether a failure toast should be shown now (once per streak).
  bool _claimFailureToast() {
    if (_failureToastShown) {
      return false;
    }
    _failureToastShown = true;
    return true;
  }

  void _noteSendSuccess() {
    _consecutiveSendFailures = 0;
    _nextRetryAt = null;
    _failureToastShown = false;
  }

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
    resetSyncCache();
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
  /// clipboard as new. Used by the manual "send now" action: the current
  /// clipboard should be pushed to the peer once, on explicit request.
  void resetSyncCache() {
    _lastKnownText = null;
    _lastSyncedText = null;
    _lastKnownImageSig = null;
    _lastSyncedImageSig = null;
  }

  /// Records the current clipboard as "already seen" without sending it.
  ///
  /// Used when a peer is (re)selected or clipboard sync is switched on:
  /// pairing must never blast whatever happens to be on the clipboard to
  /// the other device. Only copies made *after* setup are synced.
  Future<void> primeCache() async {
    start();
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text != null && text.isNotEmpty) {
        _lastKnownText = text;
        _lastSyncedText = text;
        return;
      }
    } catch (e) {
      _logger.fine('Priming clipboard text cache failed: $e');
    }
    try {
      final bytes = checkPlatform([TargetPlatform.android]) ? await android_channel.getClipboardImageAndroid() : await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        final signature = _imageSignature(bytes);
        _lastKnownImageSig = signature;
        _lastSyncedImageSig = signature;
      }
    } catch (e) {
      _logger.fine('Priming clipboard image cache failed: $e');
    }
  }

  /// Called by the receiver when clipboard text was applied from the peer,
  /// so the poller does not send it back.
  void markReceived(String text) {
    _lastSyncedText = text;
    _lastKnownText = text;
    state = state.copyWith(lastReceivedAt: DateTime.now());
  }

  /// Called by the receiver when a clipboard image was applied from the
  /// peer, so the poller does not send it back.
  void markReceivedImage(Uint8List bytes) {
    final signature = _imageSignature(bytes);
    _lastSyncedImageSig = signature;
    _lastKnownImageSig = signature;
    state = state.copyWith(lastReceivedAt: DateTime.now());
  }

  /// Sends [files] in a background session and reports how it ended.
  /// `startSession` also returns normally when the peer declines or cannot
  /// be reached, so the sync bookkeeping must not treat every return as
  /// success — otherwise a failed sync would be marked as done and never
  /// retried. A *rejected* send means the peer has not agreed to this sync
  /// (not paired back / feature off there): the same content must not be
  /// retried over and over. Other failures are transient and retried.
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
      // No text on the clipboard: maybe an image was copied instead.
      await _pollImage();
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
      // Peer not in the discovery list right now: wait silently. The
      // content stays pending and is sent when the peer appears again.
      return;
    }
    if (_retryPending(now)) {
      // A recent send failed; retry silently after the backoff delay.
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
      showSyncToastLocalized(en: 'Sending clipboard text to ${peer.alias}…', vi: 'Đang gửi clipboard chữ tới ${peer.alias}…');
      final outcome = await _sendInBackground(peer: peer, files: [file]);
      if (outcome != _SendOutcome.sent) {
        if (outcome == _SendOutcome.rejected) {
          // The peer has not agreed to clipboard sync (yet). Remember this
          // text as seen so it is not offered again on every poll; a new
          // copy, a settings change or "send now" retries.
          _lastKnownText = current;
          await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(false);
          state = state.copyWith(lastError: 'Waiting for ${peer.alias} to favorite this device and enable clipboard sync');
          showSyncToastLocalized(
            en: 'Waiting for ${peer.alias} to enable clipboard sync',
            vi: 'Đang chờ ${peer.alias} bật đồng bộ clipboard',
          );
        } else {
          _noteSendFailure();
          state = state.copyWith(lastError: 'Clipboard text was not accepted by ${peer.alias}');
          if (_claimFailureToast()) {
            showSyncToastLocalized(en: 'Clipboard text sync failed', vi: 'Đồng bộ clipboard chữ thất bại');
          }
        }
        return;
      }
      _noteSendSuccess();
      _lastSyncedText = current;
      _lastKnownText = current;
      _lastSendAt = now;
      await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(true);
      state = state.copyWith(lastSentAt: now, clearError: true);
      showSyncToastLocalized(en: 'Clipboard text sent to ${peer.alias}', vi: 'Đã gửi clipboard chữ tới ${peer.alias}');
      _logger.info('Clipboard synced to ${peer.alias} (${bytes.length} bytes)');
    } catch (e) {
      _logger.warning('Clipboard sync send failed: $e');
      _noteSendFailure();
      state = state.copyWith(lastError: e.toString());
      if (_claimFailureToast()) {
        showSyncToastLocalized(en: 'Clipboard text sync failed', vi: 'Đồng bộ clipboard chữ thất bại');
      }
    } finally {
      _sending = false;
    }
  }

  /// Image counterpart of the text poll: reads the clipboard image (via the
  /// same `pasteboard` plugin the manual "Paste" action uses) and sends it
  /// as a regular file named `__clipboard_sync__.<ext>`. The receiver
  /// recognizes the name and writes it back to its clipboard.
  Future<void> _pollImage() async {
    Uint8List? bytes;
    try {
      // On Android the pasteboard plugin misses image clips on some devices,
      // so read the clipboard through the app's own platform channel there.
      bytes = checkPlatform([TargetPlatform.android]) ? await android_channel.getClipboardImageAndroid() : await Pasteboard.image;
    } catch (e) {
      // No image access (e.g. background on mobile). Retry next tick.
      _logger.fine('Clipboard image read failed: $e');
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    if (bytes.length > maxClipboardImageBytes) {
      _logger.info('Clipboard image too large (${bytes.length} bytes), skipped');
      _lastKnownImageSig = _imageSignature(bytes);
      return;
    }

    final signature = _imageSignature(bytes);
    if (signature == _lastSyncedImageSig) {
      // Already synced (sent or received). Just track it.
      _lastKnownImageSig = signature;
      return;
    }
    if (signature == _lastKnownImageSig) {
      // Unchanged since last poll.
      return;
    }

    final now = DateTime.now();
    if (_lastSendAt != null && now.difference(_lastSendAt!) < _minSendInterval) {
      // Rate limited. Keep the signature stale so we retry next tick.
      return;
    }

    final peer = resolveSyncPeer(ref);
    if (peer == null) {
      // Peer not in the discovery list right now: wait silently. The
      // image stays pending and is sent when the peer appears again.
      return;
    }
    if (_retryPending(now)) {
      // A recent send failed; retry silently after the backoff delay.
      return;
    }

    // On Windows the clipboard image is a BMP which is large and
    // inefficient. Convert it to PNG like the manual "Paste" action does.
    var imageBytes = bytes;
    var imageType = determineImageType(bytes);
    if (imageType == 'bmp') {
      try {
        imageBytes = await convertBmpToPng(bytes);
        imageType = 'png';
      } catch (e) {
        // Conversion failed: send the BMP as-is.
      }
    }

    _sending = true;
    try {
      final file = CrossFile(
        name: '$clipboardSyncImagePrefix$imageType',
        fileType: FileType.image,
        size: imageBytes.length,
        thumbnail: null,
        asset: null,
        path: null,
        bytes: imageBytes,
        lastModified: null,
        lastAccessed: null,
      );
      showSyncToastLocalized(en: 'Sending clipboard image to ${peer.alias}…', vi: 'Đang gửi clipboard hình ảnh tới ${peer.alias}…');
      final outcome = await _sendInBackground(peer: peer, files: [file]);
      if (outcome != _SendOutcome.sent) {
        if (outcome == _SendOutcome.rejected) {
          // Same anti-spam rule as for text: do not re-offer this image
          // until the clipboard changes or the user retries manually.
          _lastKnownImageSig = signature;
          await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(false);
          state = state.copyWith(lastError: 'Waiting for ${peer.alias} to favorite this device and enable clipboard sync');
          showSyncToastLocalized(
            en: 'Waiting for ${peer.alias} to enable clipboard sync',
            vi: 'Đang chờ ${peer.alias} bật đồng bộ clipboard',
          );
        } else {
          _noteSendFailure();
          state = state.copyWith(lastError: 'Clipboard image was not accepted by ${peer.alias}');
          if (_claimFailureToast()) {
            showSyncToastLocalized(en: 'Clipboard image sync failed', vi: 'Đồng bộ clipboard hình ảnh thất bại');
          }
        }
        return;
      }
      _noteSendSuccess();
      _lastSyncedImageSig = signature;
      _lastKnownImageSig = signature;
      _lastSendAt = now;
      await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(true);
      state = state.copyWith(lastSentAt: now, clearError: true);
      showSyncToastLocalized(en: 'Clipboard image sent to ${peer.alias}', vi: 'Đã gửi clipboard hình ảnh tới ${peer.alias}');
      _logger.info('Clipboard image synced to ${peer.alias} (${imageBytes.length} bytes)');
    } catch (e) {
      _logger.warning('Clipboard image sync send failed: $e');
      _noteSendFailure();
      state = state.copyWith(lastError: e.toString());
      if (_claimFailureToast()) {
        showSyncToastLocalized(en: 'Clipboard image sync failed', vi: 'Đồng bộ clipboard hình ảnh thất bại');
      }
    } finally {
      _sending = false;
    }
  }

  /// Cheap fingerprint of clipboard image bytes: the length plus an FNV-1a
  /// hash over three sampled chunks. Recognizes an unchanged screenshot
  /// without storing megabytes in memory.
  String _imageSignature(Uint8List bytes) {
    var hash = 0xcbf29ce484222325;
    void mixRange(int start, int end) {
      for (var i = start; i < end; i++) {
        hash ^= bytes[i];
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
    }

    const chunk = 4096;
    mixRange(0, bytes.length < chunk ? bytes.length : chunk);
    if (bytes.length > chunk) {
      final mid = bytes.length ~/ 2;
      mixRange(mid, mid + chunk > bytes.length ? bytes.length : mid + chunk);
      mixRange(bytes.length - chunk, bytes.length);
    }
    return '${bytes.length}:$hash';
  }
}
