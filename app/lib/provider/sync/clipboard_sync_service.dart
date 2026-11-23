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

  /// What the poller currently sees on the clipboard, e.g.
  /// `image 812 KB`, `text 42 chars`, `no image detected (items=1: ...)`.
  /// Shown in the paired-sync settings to diagnose sync issues.
  final String? clipboardDiagnostic;

  const ClipboardSyncState({
    required this.running,
    required this.lastPollAt,
    required this.lastSentAt,
    required this.lastReceivedAt,
    required this.lastError,
    required this.clipboardDiagnostic,
  });

  static const initial = ClipboardSyncState(
    running: false,
    lastPollAt: null,
    lastSentAt: null,
    lastReceivedAt: null,
    lastError: null,
    clipboardDiagnostic: null,
  );

  ClipboardSyncState copyWith({
    bool? running,
    DateTime? lastPollAt,
    DateTime? lastSentAt,
    DateTime? lastReceivedAt,
    String? lastError,
    bool clearError = false,
    String? clipboardDiagnostic,
  }) {
    return ClipboardSyncState(
      running: running ?? this.running,
      lastPollAt: lastPollAt ?? this.lastPollAt,
      lastSentAt: lastSentAt ?? this.lastSentAt,
      lastReceivedAt: lastReceivedAt ?? this.lastReceivedAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
      clipboardDiagnostic: clipboardDiagnostic ?? this.clipboardDiagnostic,
    );
  }
}

final clipboardSyncProvider = NotifierProvider<ClipboardSyncService, ClipboardSyncState>((ref) {
  return ClipboardSyncService();
});

/// Per-peer transient-failure bookkeeping. Peers are independent: one
/// peer failing (or being offline) must not block, delay or spam-report
/// sync with the others.
class _PeerRetryState {
  int consecutiveFailures = 0;
  DateTime? nextRetryAt;
  bool failureToastShown = false;
}

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

  /// Last text received from a peer (or primed at setup). It is never
  /// sent anywhere: pairs are independent, so content received from one
  /// peer is not forwarded to another peer either.
  String? _suppressedText;

  /// Last text successfully sent to each peer (by fingerprint).
  final Map<String, String> _textSentToPeer = {};

  /// Last text each peer rejected (not paired back / feature off there).
  /// The same text is not offered to that peer again; other peers are
  /// unaffected.
  final Map<String, String> _textRejectedByPeer = {};

  /// Signature of the last image received from a peer (or primed at
  /// setup). Never sent anywhere (see [_suppressedText]).
  String? _suppressedImageSig;

  /// Signature of the last image successfully sent to each peer.
  final Map<String, String> _imageSentToPeer = {};

  /// Signature of the last image each peer rejected.
  final Map<String, String> _imageRejectedByPeer = {};

  DateTime? _lastSendAt;

  /// Whether the current "no image" diagnostic (incl. the native debug
  /// string) has already been fetched for this clipboard content, so the
  /// debug channel call happens once per change, not every poll.
  bool _noImageDiagnosticFetched = false;

  void _setDiagnostic(String diagnostic) {
    if (state.clipboardDiagnostic != diagnostic) {
      state = state.copyWith(clipboardDiagnostic: diagnostic);
    }
  }

  /// Transient send failures are retried silently with a growing delay;
  /// the user only gets one failure toast per failure streak and peer,
  /// not one per poll.
  final Map<String, _PeerRetryState> _retryByPeer = {};

  @override
  ClipboardSyncState init() => ClipboardSyncState.initial;

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
    _suppressedText = null;
    _textSentToPeer.clear();
    _textRejectedByPeer.clear();
    _suppressedImageSig = null;
    _imageSentToPeer.clear();
    _imageRejectedByPeer.clear();
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
        _suppressedText = text;
        return;
      }
    } catch (e) {
      _logger.fine('Priming clipboard text cache failed: $e');
    }
    try {
      final bytes = checkPlatform([TargetPlatform.android]) ? await android_channel.getClipboardImageAndroid() : await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        _suppressedImageSig = _imageSignature(bytes);
      }
    } catch (e) {
      _logger.fine('Priming clipboard image cache failed: $e');
    }
  }

  /// Called by the receiver when clipboard text was applied from the peer,
  /// so the poller does not send it back.
  void markReceived(String text) {
    _suppressedText = text;
    state = state.copyWith(lastReceivedAt: DateTime.now());
  }

  /// Called by the receiver when a clipboard image was applied from the
  /// peer, so the poller does not send it back.
  void markReceivedImage(Uint8List bytes) {
    _suppressedImageSig = _imageSignature(bytes);
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

    if (checkPlatform([TargetPlatform.android])) {
      // Android first: an image clip holds a content URI, and the text
      // reader below would surface that URI as pseudo-text, so checking
      // text first would never reach the image branch.
      if (await _pollImage()) {
        return;
      }
    }

    String? current;
    try {
      current = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (e) {
      // No clipboard access (e.g. background on mobile). Retry next tick.
      _logger.fine('Clipboard read failed: $e');
      return;
    }

    if (current == null || current.isEmpty) {
      // No text on the clipboard: maybe an image was copied instead
      // (Android already checked above).
      if (!checkPlatform([TargetPlatform.android])) {
        await _pollImage();
      }
      return;
    }
    if (current.startsWith('content://')) {
      // Pseudo-text: the string form of an image clip's URI (Android).
      // Never sync it as text; the image branch above handles the clip.
      return;
    }
    _setDiagnostic('text ${current.length} chars');
    if (current == _suppressedText) {
      // Received from a peer (or primed at setup): never echo it back and
      // never forward it to other peers. Pairs are independent.
      return;
    }

    final bytes = utf8.encode(current);
    if (bytes.length > maxClipboardSyncBytes) {
      _logger.info('Clipboard text too large (${bytes.length} bytes), skipped');
      _suppressedText = current;
      return;
    }

    // Fan out to every paired peer that is currently discovered. Peers
    // that are offline simply stay pending: their per-peer sent marker is
    // not set, so the text goes out as soon as they appear again.
    final peers = resolveSyncPeers(ref);
    if (peers.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final pending = peers
        .where(
          (peer) =>
              _textSentToPeer[peer.fingerprint] != current &&
              _textRejectedByPeer[peer.fingerprint] != current &&
              !_retryPending(peer.fingerprint, now),
        )
        .toList();
    if (pending.isEmpty) {
      // Every online peer already has this text (or rejected it).
      return;
    }
    if (_lastSendAt != null && now.difference(_lastSendAt!) < _minSendInterval) {
      // Rate limited. The per-peer markers stay unset, so the pending
      // peers are retried on a later tick.
      return;
    }

    _sending = true;
    var anySent = false;
    try {
      for (final peer in pending) {
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
          if (outcome == _SendOutcome.rejected) {
            // This peer has not agreed to clipboard sync (yet). Do not
            // offer it this text again; other peers are unaffected. A new
            // copy, a settings change or "send now" retries.
            _textRejectedByPeer[peer.fingerprint] = current;
            await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(peer.fingerprint, false);
            state = state.copyWith(lastError: 'Waiting for ${peer.alias} to favorite this device and enable clipboard sync');
            showSyncToastLocalized(
              en: 'Waiting for ${peer.alias} to enable clipboard sync',
              vi: 'Đang chờ ${peer.alias} bật đồng bộ clipboard',
            );
          } else if (outcome == _SendOutcome.failed) {
            _noteSendFailure(peer.fingerprint);
            state = state.copyWith(lastError: 'Clipboard text was not accepted by ${peer.alias}');
            if (_claimFailureToast(peer.fingerprint)) {
              showSyncToastLocalized(en: 'Clipboard text sync failed', vi: 'Đồng bộ clipboard chữ thất bại');
            }
          } else {
            _noteSendSuccess(peer.fingerprint);
            _textSentToPeer[peer.fingerprint] = current;
            _textRejectedByPeer.remove(peer.fingerprint);
            anySent = true;
            await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(peer.fingerprint, true);
            state = state.copyWith(lastSentAt: DateTime.now(), clearError: true);
            showSyncToastLocalized(en: 'Clipboard text sent to ${peer.alias}', vi: 'Đã gửi clipboard chữ tới ${peer.alias}');
            _logger.info('Clipboard synced to ${peer.alias} (${bytes.length} bytes)');
          }
        } catch (e) {
          _logger.warning('Clipboard sync send to ${peer.alias} failed: $e');
          _noteSendFailure(peer.fingerprint);
          state = state.copyWith(lastError: e.toString());
          if (_claimFailureToast(peer.fingerprint)) {
            showSyncToastLocalized(en: 'Clipboard text sync failed', vi: 'Đồng bộ clipboard chữ thất bại');
          }
        }
      }
    } finally {
      _sending = false;
    }
    if (anySent) {
      _lastSendAt = DateTime.now();
    }
  }

  /// Image counterpart of the text poll: reads the clipboard image (via the
  /// same `pasteboard` plugin the manual "Paste" action uses) and sends it
  /// as a regular file named `__clipboard_sync__.<ext>`. The receiver
  /// recognizes the name and writes it back to its clipboard.
  /// Returns true when the clipboard currently holds an image (whether
  /// it was sent, already synced, or skipped), so the caller does not
  /// fall through to the text branch for the same clip.
  Future<bool> _pollImage() async {
    Uint8List? bytes;
    try {
      // On Android the pasteboard plugin misses image clips on some devices,
      // so read the clipboard through the app's own platform channel there.
      bytes = checkPlatform([TargetPlatform.android]) ? await android_channel.getClipboardImageAndroid() : await Pasteboard.image;
    } catch (e) {
      // No image access (e.g. background on mobile). Retry next tick.
      _logger.fine('Clipboard image read failed: $e');
      final message = e.toString();
      _setDiagnostic('image read failed: ${message.length > 120 ? message.substring(0, 120) : message}');
      return false;
    }
    if (bytes == null || bytes.isEmpty) {
      if (!_noImageDiagnosticFetched) {
        _noImageDiagnosticFetched = true;
        var diagnostic = 'no image detected';
        if (checkPlatform([TargetPlatform.android])) {
          try {
            final debug = await android_channel.getClipboardImageDebugAndroid();
            if (debug != null && debug.isNotEmpty) {
              diagnostic = 'no image detected ($debug)';
            }
          } catch (e) {
            // Diagnostic only: ignore failures.
          }
        }
        _setDiagnostic(diagnostic);
      }
      return false;
    }
    _noImageDiagnosticFetched = false;
    _setDiagnostic('image ${(bytes.length / 1024).round()} KB');
    final signature = _imageSignature(bytes);
    if (bytes.length > maxClipboardImageBytes) {
      _logger.info('Clipboard image too large (${bytes.length} bytes), skipped');
      _suppressedImageSig = signature;
      return true;
    }
    if (signature == _suppressedImageSig) {
      // Received from a peer (or primed at setup): never echo or forward.
      return true;
    }

    // Same fan-out as text: every discovered paired peer that has not
    // received (or rejected) this image yet gets it; offline peers stay
    // pending via their missing per-peer marker.
    final peers = resolveSyncPeers(ref);
    if (peers.isEmpty) {
      return true;
    }
    final now = DateTime.now();
    final pending = peers
        .where(
          (peer) =>
              _imageSentToPeer[peer.fingerprint] != signature &&
              _imageRejectedByPeer[peer.fingerprint] != signature &&
              !_retryPending(peer.fingerprint, now),
        )
        .toList();
    if (pending.isEmpty) {
      return true;
    }
    if (_lastSendAt != null && now.difference(_lastSendAt!) < _minSendInterval) {
      // Rate limited. The per-peer markers stay unset, so the pending
      // peers are retried on a later tick.
      return true;
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
    var anySent = false;
    try {
      for (final peer in pending) {
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
          if (outcome == _SendOutcome.rejected) {
            // Same anti-spam rule as for text, but per peer: this image is
            // not re-offered to this peer; others are unaffected.
            _imageRejectedByPeer[peer.fingerprint] = signature;
            await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(peer.fingerprint, false);
            state = state.copyWith(lastError: 'Waiting for ${peer.alias} to favorite this device and enable clipboard sync');
            showSyncToastLocalized(
              en: 'Waiting for ${peer.alias} to enable clipboard sync',
              vi: 'Đang chờ ${peer.alias} bật đồng bộ clipboard',
            );
          } else if (outcome == _SendOutcome.failed) {
            _noteSendFailure(peer.fingerprint);
            state = state.copyWith(lastError: 'Clipboard image was not accepted by ${peer.alias}');
            if (_claimFailureToast(peer.fingerprint)) {
              showSyncToastLocalized(en: 'Clipboard image sync failed', vi: 'Đồng bộ clipboard hình ảnh thất bại');
            }
          } else {
            _noteSendSuccess(peer.fingerprint);
            _imageSentToPeer[peer.fingerprint] = signature;
            _imageRejectedByPeer.remove(peer.fingerprint);
            anySent = true;
            await ref.notifier(syncSettingsProvider).setClipboardPeerConfirmed(peer.fingerprint, true);
            state = state.copyWith(lastSentAt: DateTime.now(), clearError: true);
            showSyncToastLocalized(en: 'Clipboard image sent to ${peer.alias}', vi: 'Đã gửi clipboard hình ảnh tới ${peer.alias}');
            _logger.info('Clipboard image synced to ${peer.alias} (${imageBytes.length} bytes)');
          }
        } catch (e) {
          _logger.warning('Clipboard image sync send to ${peer.alias} failed: $e');
          _noteSendFailure(peer.fingerprint);
          state = state.copyWith(lastError: e.toString());
          if (_claimFailureToast(peer.fingerprint)) {
            showSyncToastLocalized(en: 'Clipboard image sync failed', vi: 'Đồng bộ clipboard hình ảnh thất bại');
          }
        }
      }
    } finally {
      _sending = false;
    }
    if (anySent) {
      _lastSendAt = DateTime.now();
    }
    return true;
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
