import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync/background_sync.dart';
import 'package:localsend_app/provider/sync/clipboard_sync_service.dart';
import 'package:localsend_app/provider/sync/folder_sync_service.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/custom_dropdown_button.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Strings of this page, in English and Vietnamese.
///
/// NOTE: Kept local to this page (instead of the slang i18n files) because
/// the generated `strings.g.dart` cannot be regenerated in every build
/// environment. Only the app language is distinguished; everything else
/// falls back to English. Migrate to slang when this gets upstreamed.
class _Strings {
  final String title;
  final String intro;
  final String helpTitle;
  final String helpBody;
  final String pairedDevice;
  final String noFavorites;
  final String online;
  final String offline;
  final String none;
  final String peer;
  final String clipboardSync;
  final String autoClipboard;
  final String clipboardNote;
  final String autoSync;
  final String running;
  final String stopped;
  final String lastCheck;
  final String lastSent;
  final String lastReceived;
  final String error;
  final String sendClipboardNow;
  final String clipboardRequested;
  final String folderSync;
  final String autoFolder;
  final String folderNote;
  final String noFolder;
  final String chooseFolder;
  final String openFolder;
  final String clearFolder;
  final String syncedFiles;
  final String lastSync;
  final String syncNow;
  final String folderRequested;
  final String privacy;
  final String consentStatus;
  final String waitingPeer;
  final String activeTwoWay;
  final String featureOff;
  final String peerOffline;

  const _Strings({
    required this.title,
    required this.intro,
    required this.helpTitle,
    required this.helpBody,
    required this.pairedDevice,
    required this.noFavorites,
    required this.online,
    required this.offline,
    required this.none,
    required this.peer,
    required this.clipboardSync,
    required this.autoClipboard,
    required this.clipboardNote,
    required this.autoSync,
    required this.running,
    required this.stopped,
    required this.lastCheck,
    required this.lastSent,
    required this.lastReceived,
    required this.error,
    required this.sendClipboardNow,
    required this.clipboardRequested,
    required this.folderSync,
    required this.autoFolder,
    required this.folderNote,
    required this.noFolder,
    required this.chooseFolder,
    required this.openFolder,
    required this.clearFolder,
    required this.syncedFiles,
    required this.lastSync,
    required this.syncNow,
    required this.folderRequested,
    required this.privacy,
    required this.consentStatus,
    required this.waitingPeer,
    required this.activeTwoWay,
    required this.featureOff,
    required this.peerOffline,
  });

  static const en = _Strings(
    title: 'Paired Sync',
    intro: 'Auto-sync with one trusted device.\nBoth devices must favorite each other and enable the same feature.',
    helpTitle: 'How it works',
    helpBody:
        'Setup: (1) Tap the heart on the same device on BOTH devices and confirm the pairing PIN. (2) Turn on a feature below on BOTH devices. (3) Only changes made after setup are synced; the current clipboard and existing folder files are not sent (use the manual sync buttons to send them once).\n\nIf the other device has not favorited this device or has not enabled the same feature, sync attempts are rejected silently there and are not retried for the same content (no spam). Sync only sends while the paired device is in the discovered list; while it is offline the app waits silently and sends when it appears again.\n\nClipboard: text up to 16 KB, images up to 8 MB. Folder: new/changed files sync both ways, deletions are not synced, last write wins.\n\nOn Android, turning sync on keeps LocalSend running in the background; reading the clipboard still only works while LocalSend is open, so after copying in another app, open LocalSend once and it will catch up.',
    pairedDevice: '1. Paired device',
    noFavorites: 'No favorites yet. Tap the heart on a device in the Send tab to favorite it (it becomes the sync peer automatically), then come back here.',
    online: 'Online',
    offline: 'Offline (waiting, not sending)',
    none: 'None',
    peer: 'Peer',
    clipboardSync: '2. Clipboard sync',
    autoClipboard: 'Auto-sync clipboard on copy',
    clipboardNote: 'Copy and it sends automatically. On Android: copy, then open LocalSend once.',
    autoSync: 'Auto-sync',
    running: 'running',
    stopped: 'stopped',
    lastCheck: 'Last check',
    lastSent: 'Last sent',
    lastReceived: 'Last received',
    error: 'Error',
    sendClipboardNow: 'Send clipboard now',
    clipboardRequested: 'Clipboard sync requested',
    folderSync: '3. Shared folder sync',
    autoFolder: 'Auto-sync shared folder',
    folderNote: 'Pick a folder, then turn this on. New/changed files sync both ways; deletions do not sync.',
    noFolder: '(no folder selected)',
    chooseFolder: 'Choose folder',
    openFolder: 'Open folder',
    clearFolder: 'Clear folder',
    syncedFiles: 'Synced files',
    lastSync: 'Last sync',
    syncNow: 'Sync now',
    folderRequested: 'Folder sync requested',
    privacy: 'Privacy: clipboard may contain passwords or one-time codes. Keep sync off unless you trust the peer. Sync uses the same encrypted connection as file transfers.',
    consentStatus: 'Two-way status',
    waitingPeer: 'Waiting for the other device (it must favorite this device and enable this feature too)',
    activeTwoWay: 'Active: both devices agreed',
    featureOff: 'Off',
    peerOffline: 'Paired device is offline (not in the discovered list right now)',
  );

  static const vi = _Strings(
    title: 'Đồng bộ theo cặp',
    intro: 'Tự đồng bộ với 1 thiết bị tin cậy.\nCả hai máy phải bấm tim nhau và bật cùng tính năng.',
    helpTitle: 'Cách hoạt động',
    helpBody:
        'Thiết lập: (1) Bấm tim cùng một thiết bị trên CẢ HAI máy và xác nhận mã PIN ghép cặp. (2) Bật tính năng bên dưới trên CẢ HAI máy. (3) Chỉ thay đổi sau khi thiết lập mới được đồng bộ; clipboard hiện tại và file sẵn trong thư mục không bị gửi (muốn gửi một lần thì bấm nút đồng bộ thủ công).\n\nNếu máy kia chưa bấm tim máy này hoặc chưa bật cùng tính năng, lần đồng bộ sẽ bị từ chối im lặng ở máy kia và không bị gửi lặp lại với cùng nội dung (không spam). App chỉ gửi khi thiết bị cặp đang có trên danh sách dò thấy; máy kia offline thì app chờ im lặng và tự gửi khi máy xuất hiện lại.\n\nClipboard: chữ tối đa 16 KB, hình ảnh tối đa 8 MB. Thư mục: file mới/thay đổi đồng bộ hai chiều, không đồng bộ file bị xoá, bản ghi sau cùng thắng.\n\nTrên Android, bật đồng bộ sẽ giữ LocalSend chạy nền; riêng việc đọc clipboard vẫn chỉ được khi LocalSend đang mở, nên copy ở app khác xong hãy mở LocalSend một lần để app tự bắt kịp.',
    pairedDevice: '1. Thiết bị đã cặp',
    noFavorites: 'Chưa có thiết bị yêu thích. Bấm biểu tượng tim trên thẻ thiết bị ở thẻ Gửi để thêm (thiết bị sẽ tự thành cặp đồng bộ), rồi quay lại đây.',
    online: 'Trực tuyến',
    offline: 'Ngoại tuyến (đang chờ, không gửi)',
    none: 'Không chọn',
    peer: 'Thiết bị cặp',
    clipboardSync: '2. Đồng bộ clipboard',
    autoClipboard: 'Tự động đồng bộ clipboard khi copy',
    clipboardNote: 'Copy là tự gửi. Trên Android: copy xong mở LocalSend một lần.',
    autoSync: 'Tự động đồng bộ',
    running: 'đang chạy',
    stopped: 'đã dừng',
    lastCheck: 'Lần kiểm tra cuối',
    lastSent: 'Lần gửi cuối',
    lastReceived: 'Lần nhận cuối',
    error: 'Lỗi',
    sendClipboardNow: 'Gửi clipboard ngay',
    clipboardRequested: 'Đã yêu cầu đồng bộ clipboard',
    folderSync: '3. Đồng bộ thư mục chung',
    autoFolder: 'Tự động đồng bộ thư mục chung',
    folderNote: 'Chọn thư mục rồi bật. File mới/thay đổi tự đồng bộ 2 chiều; xoá file không đồng bộ.',
    noFolder: '(chưa chọn thư mục)',
    chooseFolder: 'Chọn thư mục',
    openFolder: 'Mở thư mục',
    clearFolder: 'Bỏ chọn thư mục',
    syncedFiles: 'File đã đồng bộ',
    lastSync: 'Lần đồng bộ cuối',
    syncNow: 'Đồng bộ ngay',
    folderRequested: 'Đã yêu cầu đồng bộ thư mục',
    privacy: 'Riêng tư: clipboard có thể chứa mật khẩu hoặc mã OTP. Chỉ bật đồng bộ khi tin cậy thiết bị còn lại. Đồng bộ dùng cùng kết nối mã hoá như khi truyền file.',
    consentStatus: 'Trạng thái 2 chiều',
    waitingPeer: 'Đang chờ máy kia (máy kia cũng phải bấm tim máy này và bật tính năng này)',
    activeTwoWay: 'Đang hoạt động: cả hai máy đã đồng ý',
    featureOff: 'Đang tắt',
    peerOffline: 'Thiết bị cặp đang offline (hiện không có trên danh sách dò thấy)',
  );
}

/// Settings for paired-device sync: clipboard auto-sync + shared folder sync.
///
/// Pairing model: pick one Favorite device as the sync peer (favoriting a
/// device with the heart button selects it automatically). Both devices
/// must select each other. Sync only ever talks to this peer (never
/// broadcasts) and only while it can be reached on the LAN.
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final s = Localizations.localeOf(context).languageCode == 'vi' ? _Strings.vi : _Strings.en;
    final sync = ref.watch(syncSettingsProvider);
    final favorites = ref.watch(favoritesProvider);
    final nearby = ref.watch(nearbyDevicesProvider);
    final clipboardState = ref.watch(clipboardSyncProvider);
    final folderState = ref.watch(folderSyncProvider);

    final peerFingerprint = sync.syncPeerFingerprint;
    final peerFavorite = peerFingerprint == null ? null : favorites.where((e) => e.fingerprint == peerFingerprint).firstOrNull;
    final peerOnline = peerFingerprint != null && nearby.devices[peerFingerprint]?.ip != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: s.helpTitle,
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(s.helpTitle),
                  content: SingleChildScrollView(child: Text(s.helpBody)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          Text(
            s.intro,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _Section(
            title: s.pairedDevice,
            children: [
              if (favorites.isEmpty)
                Text(
                  s.noFavorites,
                  style: const TextStyle(fontSize: 13),
                )
              else
                Row(
                  children: [
                    Expanded(child: Text(peerOnline ? s.online : s.offline)),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 180,
                      child: CustomDropdownButton<String>(
                        value: peerFingerprint ?? '',
                        items: [
                          DropdownMenuItem(value: '', child: Text(s.none)),
                          for (final fav in favorites) DropdownMenuItem(value: fav.fingerprint, child: Text(fav.alias, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (fp) async {
                          await ref.notifier(syncSettingsProvider).setSyncPeerFingerprint(fp.isEmpty ? null : fp);
                          updateSyncBackgroundService(ref);
                          // Changing the peer must not send the current
                          // clipboard/folder content: only record the
                          // baseline. New changes from now on will sync.
                          ref.notifier(clipboardSyncProvider).primeCache(); // ignore: unawaited_futures
                          ref.notifier(folderSyncProvider).pollNow(); // ignore: unawaited_futures
                        },
                      ),
                    ),
                  ],
                ),
              if (peerFavorite != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${s.peer}: ${peerFavorite.alias} (${peerFavorite.ip}:${peerFavorite.port})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          _Section(
            title: s.clipboardSync,
            children: [
              _ToggleRow(
                label: s.autoClipboard,
                value: sync.clipboardSyncEnabled,
                onChanged: peerFingerprint == null
                    ? null
                    : (b) async {
                        await ref.notifier(syncSettingsProvider).setClipboardSyncEnabled(b);
                        updateSyncBackgroundService(ref);
                        if (b) {
                          // Do not send the current clipboard at setup;
                          // only the next copy is synced.
                          ref.notifier(clipboardSyncProvider).primeCache(); // ignore: unawaited_futures
                        }
                      },
              ),
              Text(
                s.clipboardNote,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${s.autoSync}: ${clipboardState.running ? s.running : s.stopped}  •  ${s.lastCheck}: ${clipboardState.lastPollAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${s.lastSent}: ${clipboardState.lastSentAt?.toLocal().toString() ?? '—'}  •  ${s.lastReceived}: ${clipboardState.lastReceivedAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${s.consentStatus}: ${!sync.clipboardSyncEnabled ? s.featureOff : sync.clipboardPeerConfirmed ? s.activeTwoWay : s.waitingPeer}',
                style: TextStyle(fontSize: 12, color: sync.clipboardSyncEnabled && sync.clipboardPeerConfirmed ? Colors.green : null),
              ),
              if (clipboardState.lastError != null) Text('${s.error}: ${clipboardState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.clipboardSyncActive
                      ? () async {
                          if (!peerOnline) {
                            // Only send while the peer is actually
                            // discovered; never dial a stale address.
                            if (context.mounted) context.showSnackBar(s.peerOffline);
                            return;
                          }
                          await ref.notifier(clipboardSyncProvider).syncNow();
                          if (context.mounted) context.showSnackBar(s.clipboardRequested);
                        }
                      : null,
                  child: Text(s.sendClipboardNow),
                ),
              ),
            ],
          ),
          _Section(
            title: s.folderSync,
            children: [
              _ToggleRow(
                label: s.autoFolder,
                value: sync.folderSyncEnabled,
                onChanged: peerFingerprint == null || sync.syncFolderPath == null
                    ? null
                    : (b) async {
                        await ref.notifier(syncSettingsProvider).setFolderSyncEnabled(b);
                        updateSyncBackgroundService(ref);
                        if (b) {
                          ref.notifier(folderSyncProvider).pollNow(); // ignore: unawaited_futures
                        }
                      },
              ),
              Text(
                s.folderNote,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sync.syncFolderPath ?? s.noFolder,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: sync.syncFolderPath == null
                        ? null
                        : () async {
                            try {
                              await openFolder(folderPath: sync.syncFolderPath!);
                            } catch (_) {
                              // Opening the folder is best-effort (some
                              // Android file managers refuse SAF trees).
                            }
                          },
                    child: Text(s.openFolder),
                  ),
                  TextButton(
                    onPressed: checkPlatformWithFileSystem()
                        ? () async {
                            final dir = await pickDirectoryPath();
                            if (dir != null) {
                              await ref.notifier(syncSettingsProvider).setSyncFolderPath(dir);
                              updateSyncBackgroundService(ref);
                              ref.notifier(folderSyncProvider).pollNow(); // ignore: unawaited_futures
                            }
                          }
                        : null,
                    child: Text(s.chooseFolder),
                  ),
                  if (sync.syncFolderPath != null)
                    IconButton(
                      tooltip: s.clearFolder,
                      onPressed: () async {
                        await ref.notifier(syncSettingsProvider).setSyncFolderPath(null);
                        updateSyncBackgroundService(ref);
                      },
                      icon: const Icon(Icons.clear),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${s.autoSync}: ${folderState.running ? s.running : s.stopped}  •  ${s.lastCheck}: ${folderState.lastPollAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                '${s.syncedFiles}: ${folderState.syncedFileCount}  •  ${s.lastSync}: ${folderState.lastSyncAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${s.consentStatus}: ${!sync.folderSyncEnabled ? s.featureOff : sync.folderPeerConfirmed ? s.activeTwoWay : s.waitingPeer}',
                style: TextStyle(fontSize: 12, color: sync.folderSyncEnabled && sync.folderPeerConfirmed ? Colors.green : null),
              ),
              if (folderState.lastError != null) Text('${s.error}: ${folderState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.folderSyncActive
                      ? () async {
                          if (!peerOnline) {
                            // Only send while the peer is actually
                            // discovered; never dial a stale address.
                            if (context.mounted) context.showSnackBar(s.peerOffline);
                            return;
                          }
                          await ref.notifier(folderSyncProvider).syncNow();
                          if (context.mounted) context.showSnackBar(s.folderRequested);
                        }
                      : null,
                  child: Text(s.syncNow),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            s.privacy,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.only(left: 15, right: 15, top: 15, bottom: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ToggleRow({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 10),
          SizedBox(
            width: 60,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: theme.colorScheme.primary,
              activeThumbColor: theme.colorScheme.onPrimary,
              inactiveThumbColor: theme.colorScheme.outline,
              inactiveTrackColor: theme.colorScheme.surface,
            ),
          ),
        ],
      ),
    );
  }
}
