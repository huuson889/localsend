import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/sync/clipboard_sync_service.dart';
import 'package:localsend_app/provider/sync/folder_sync_service.dart';
import 'package:localsend_app/provider/sync_settings_provider.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/custom_dropdown_button.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

// NOTE: Labels are hardcoded in English for now (no codegen available in this
// environment). Move them to app/assets/i18n/en.json + vi.json and regenerate
// strings when the feature is upstreamed.

/// Settings for paired-device sync: clipboard auto-sync + shared folder sync.
///
/// Pairing model: pick one Favorite device as the sync peer. Both devices
/// must select each other. Sync only ever talks to this peer (never
/// broadcasts) and only while it is discovered on the LAN.
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final sync = ref.watch(syncSettingsProvider);
    final favorites = ref.watch(favoritesProvider);
    final nearby = ref.watch(nearbyDevicesProvider);
    final clipboardState = ref.watch(clipboardSyncProvider);
    final folderState = ref.watch(folderSyncProvider);

    final peerFingerprint = sync.syncPeerFingerprint;
    final peerFavorite = peerFingerprint == null ? null : favorites.where((e) => e.fingerprint == peerFingerprint).firstOrNull;
    final peerOnline = peerFingerprint != null && nearby.devices.containsKey(peerFingerprint);

    return Scaffold(
      appBar: AppBar(title: const Text('Paired Sync')),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          const Text(
            'Sync with one trusted device: clipboard auto-sync on copy + a shared folder that syncs new/changed files both ways.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Both devices must select each other here. Sync only runs while both apps are open and discoverable on the same network.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 20),
          _Section(
            title: 'Paired device',
            children: [
              if (favorites.isEmpty)
                const Text(
                  'No favorites yet. On the Send tab, open a device menu and choose "Add to favorites" first, then come back here.',
                  style: TextStyle(fontSize: 13),
                )
              else
                Row(
                  children: [
                    Expanded(child: Text(peerOnline ? 'Online' : 'Offline (will retry)')),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 180,
                      child: CustomDropdownButton<String>(
                        value: peerFingerprint ?? '',
                        items: [
                          const DropdownMenuItem(value: '', child: Text('None')),
                          for (final fav in favorites) DropdownMenuItem(value: fav.fingerprint, child: Text(fav.alias, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (fp) async {
                          await ref.notifier(syncSettingsProvider).setSyncPeerFingerprint(fp.isEmpty ? null : fp);
                        },
                      ),
                    ),
                  ],
                ),
              if (peerFavorite != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Peer: ${peerFavorite.alias} (${peerFavorite.ip}:${peerFavorite.port})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          _Section(
            title: 'Clipboard sync',
            children: [
              _ToggleRow(
                label: 'Auto-sync clipboard on copy',
                value: sync.clipboardSyncEnabled,
                onChanged: peerFingerprint == null
                    ? null
                    : (b) async {
                        await ref.notifier(syncSettingsProvider).setClipboardSyncEnabled(b);
                      },
              ),
              const Text(
                'Text only, up to 16 KB. Desktop works while the app runs (even minimized to tray). On Android/iOS the OS restricts background clipboard access, so sync happens while the app is in the foreground.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                'Last sent: ${clipboardState.lastSentAt?.toLocal().toString() ?? '—'}  •  Last received: ${clipboardState.lastReceivedAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              if (clipboardState.lastError != null) Text('Error: ${clipboardState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.clipboardSyncActive
                      ? () async {
                          await ref.notifier(clipboardSyncProvider).syncNow();
                          if (context.mounted) context.showSnackBar('Clipboard sync requested');
                        }
                      : null,
                  child: const Text('Send clipboard now'),
                ),
              ),
            ],
          ),
          _Section(
            title: 'Shared folder sync',
            children: [
              _ToggleRow(
                label: 'Auto-sync shared folder',
                value: sync.folderSyncEnabled,
                onChanged: peerFingerprint == null
                    ? null
                    : (b) async {
                        await ref.notifier(syncSettingsProvider).setFolderSyncEnabled(b);
                      },
              ),
              const Text(
                'New and changed files sync both ways (subfolders preserved). Deletions are not synced. If both sides edit the same file, last write wins.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sync.syncFolderPath ?? '(no folder selected)',
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
                            }
                          }
                        : null,
                    child: const Text('Choose folder'),
                  ),
                  if (sync.syncFolderPath != null)
                    IconButton(
                      tooltip: 'Clear folder',
                      onPressed: () async {
                        await ref.notifier(syncSettingsProvider).setSyncFolderPath(null);
                      },
                      icon: const Icon(Icons.clear),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Synced files: ${folderState.syncedFileCount}  •  Last sync: ${folderState.lastSyncAt?.toLocal().toString() ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              if (folderState.lastError != null) Text('Error: ${folderState.lastError}', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: sync.folderSyncActive
                      ? () async {
                          await ref.notifier(folderSyncProvider).syncNow();
                          if (context.mounted) context.showSnackBar('Folder sync requested');
                        }
                      : null,
                  child: const Text('Sync now'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Privacy: clipboard may contain passwords or one-time codes. Keep sync off unless you trust the peer. Sync uses the same encrypted connection as file transfers.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
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
