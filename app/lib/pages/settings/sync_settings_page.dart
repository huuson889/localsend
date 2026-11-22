import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync/background_sync.dart';
import 'package:localsend_app/provider/sync/clipboard_sync_service.dart';
import 'package:localsend_app/provider/sync/folder_sync_service.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
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
  final String introNote;
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
  final String clearFolder;
  final String syncedFiles;
  final String lastSync;
  final String syncNow;
  final String folderRequested;
  final String privacy;

  const _Strings({
    required this.title,
    required this.intro,
    required this.introNote,
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
    required this.clearFolder,
    required this.syncedFiles,
    required this.lastSync,
    required this.syncNow,
    required this.folderRequested,
    required this.privacy,
  });

  static const en = _Strings(
    title: 'Paired Sync',
    intro: 'Sync with one trusted device: clipboard auto-sync on copy (text and images) plus a shared folder that syncs new/changed files both ways.',
    introNote:
        'Both devices must select each other here and be on the same network. On Android, turning sync on keeps LocalSend running in the background (persistent notification) so folder sync continues with the app closed. Reading the clipboard on Android still only works while the app is open.',
    pairedDevice: 'Paired device',
    noFavorites: 'No favorites yet. Tap the heart on a device in the Send tab to favorite it (it becomes the sync peer automatically), then come back here.',
    online: 'Online',
    offline: 'Offline (will retry)',
    none: 'None',
    peer: 'Peer',
    clipboardSync: 'Clipboard sync',
    autoClipboard: 'Auto-sync clipboard on copy',
    clipboardNote:
        'Text up to 16 KB and images up to 8 MB. Desktop works while the app runs (even minimized to tray). On Android the app stays alive in the background, but the OS only lets apps read the clipboard while in the foreground, so copy while LocalSend is open.',
    autoSync: 'Auto-sync',
    running: 'running',
    stopped: 'stopped',
    lastCheck: 'Last check',
    lastSent: 'Last sent',
    lastReceived: 'Last received',
    error: 'Error',
    sendClipboardNow: 'Send clipboard now',
    clipboardRequested: 'Clipboard sync requested',
    folderSync: 'Shared folder sync',
    autoFolder: 'Auto-sync shared folder',
    folderNote: 'New and changed files sync both ways (subfolders preserved). Deletions are not synced. If both sides edit the same file, last write wins.',
    noFolder: '(no folder selected)',
    chooseFolder: 'Choose folder',
    clearFolder: 'Clear folder',
    syncedFiles: 'Synced files',
    lastSync: 'Last sync',
    syncNow: 'Sync now',
    folderRequested: 'Folder sync requested',
    privacy: 'Privacy: clipboard may contain passwords or one-time codes. Keep sync off unless you trust the peer. Sync uses the same encrypted connection as file transfers.',
  );

  static const vi = _Strings(
    title: 'Đồng bộ theo cặp',
    intro: 'Đồng bộ với một thiết bị tin cậy: tự động đồng bộ clipboard khi copy (cả chữ và hình ảnh), cộng thêm một thư mục chung tự đồng bộ file mới/thay đổi theo cả hai chiều.',
    introNote:
        'Cả hai thiết bị phải chọn nhau tại đây và dùng chung một mạng. Trên Android, bật đồng bộ sẽ giữ LocalSend chạy nền (có thông báo thường trực) để thư mục tiếp tục đồng bộ kể cả khi đóng app. Riêng việc đọc clipboard trên Android vẫn chỉ thực hiện được khi app đang mở.',
    pairedDevice: 'Thiết bị đã cặp',
    noFavorites: 'Chưa có thiết bị yêu thích. Bấm biểu tượng tim trên thẻ thiết bị ở thẻ Gửi để thêm (thiết bị sẽ tự thành cặp đồng bộ), rồi quay lại đây.',
    online: 'Trực tuyến',
    offline: 'Ngoại tuyến (sẽ thử lại)',
    none: 'Không chọn',
    peer: 'Thiết bị cặp',
    clipboardSync: 'Đồng bộ clipboard',
    autoClipboard: 'Tự động đồng bộ clipboard khi copy',
    clipboardNote:
        'Chữ tối đa 16 KB, hình ảnh tối đa 8 MB. Máy tính hoạt động khi app đang chạy (kể cả thu nhỏ xuống tray). Trên Android app được giữ chạy nền, nhưng hệ điều hành chỉ cho đọc clipboard khi app ở tiền cảnh, nên hãy copy khi LocalSend đang mở.',
    autoSync: 'Tự động đồng bộ',
    running: 'đang chạy',
    stopped: 'đã dừng',
    lastCheck: 'Lần kiểm tra cuối',
    lastSent: 'Lần gửi cuối',
    lastReceived: 'Lần nhận cuối',
    error: 'Lỗi',
    sendClipboardNow: 'Gửi clipboard ngay',
    clipboardRequested: 'Đã yêu cầu đồng bộ clipboard',
    folderSync: 'Đồng bộ thư mục chung',
    autoFolder: 'Tự động đồng bộ thư mục chung',
    folderNote: 'File mới và file thay đổi sẽ đồng bộ hai chiều (giữ nguyên thư mục con). Không đồng bộ file bị xoá. Nếu hai bên sửa cùng một file, bản ghi sau cùng sẽ thắng.',
    noFolder: '(chưa chọn thư mục)',
    chooseFolder: 'Chọn thư mục',
    clearFolder: 'Bỏ chọn thư mục',
    syncedFiles: 'File đã đồng bộ',
    lastSync: 'Lần đồng bộ cuối',
    syncNow: 'Đồng bộ ngay',
    folderRequested: 'Đã yêu cầu đồng bộ thư mục',
    privacy: 'Riêng tư: clipboard có thể chứa mật khẩu hoặc mã OTP. Chỉ bật đồng bộ khi tin cậy thiết bị còn lại. Đồng bộ dùng cùng kết nối mã hoá như khi truyền file.',
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
    final peerOnline = peerFingerprint != null && nearby.devices.containsKey(peerFingerprint);

    return Scaffold(
      appBar: AppBar(title: Text(s.title)),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          Text(
            s.intro,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            s.introNote,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
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
                          ref.notifier(clipboardSyncProvider).resetSyncCache();
                          ref.notifier(clipboardSyncProvider).pollNow(); // ignore: unawaited_futures
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
                          ref.notifier(clipboardSyncProvider).resetSyncCache();
                          ref.notifier(clipboardSyncProvider).pollNow(); // ignore: unawaited_futures
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
              if (clipboardState.lastError != null) Text('${s.error}: ${clipboardState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.clipboardSyncActive
                      ? () async {
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
                onChanged: peerFingerprint == null
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
              if (folderState.lastError != null) Text('${s.error}: ${folderState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.folderSyncActive
                      ? () async {
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
