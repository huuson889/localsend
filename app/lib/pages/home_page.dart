import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/settings/sync_settings_page.dart';
import 'package:localsend_app/pages/tabs/receive_tab.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/sync/pairing_service.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum HomeTab {
  receive(Icons.wifi),
  send(Icons.send),
  sync(Icons.sync),
  settings(Icons.settings)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.receive:
        return t.receiveTab.title;
      case HomeTab.send:
        return t.sendTab.title;
      case HomeTab.sync:
        return LocaleSettings.currentLocale.languageCode == 'vi' ? 'Đồng bộ cặp' : 'Paired Sync';
      case HomeTab.settings:
        return t.settingsTab.title;
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;
  bool _pairingDialogVisible = false;

  @override
  void initState() {
    super.initState();

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);

    // Pairing (PIN) dialogs are global: they must appear no matter which
    // tab is open, because the request can arrive at any time.
    final pairing = context.watch(pairingProvider);
    if ((pairing.incoming != null || pairing.outgoing != null) && !_pairingDialogVisible) {
      _pairingDialogVisible = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        // ignore: discarded_futures
        showDialog(context: context, barrierDismissible: false, builder: (_) => const _PairingDialog()).whenComplete(() {
          _pairingDialogVisible = false;
        });
      });
    }

    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _dragAndDropIndicator = true;
        });
      },
      onDragExited: (_) {
        setState(() {
          _dragAndDropIndicator = false;
        });
      },
      onDragDone: (event) async {
        // the drop may contain a mix of files and directories
        final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
        final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

        for (final directory in droppedDirectories) {
          await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
        }

        if (droppedFiles.isNotEmpty) {
          await ref
              .redux(selectedSendingFilesProvider)
              .dispatchAsync(
                AddFilesAction(
                  files: droppedFiles,
                  converter: CrossFileConverters.convertXFile,
                ),
              );
        }
        vm.changeTab(HomeTab.send);
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  NavigationRail(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    extended: sizingInformation.isDesktop,
                    backgroundColor: Theme.of(context).cardColorWithElevation,
                    leading: sizingInformation.isDesktop
                        ? const Column(
                            children: [
                              SizedBox(height: 20),
                              Text(
                                'LocalSend',
                                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              SizedBox(height: 20),
                            ],
                          )
                        : null,
                    destinations: HomeTab.values.map((tab) {
                      return NavigationRailDestination(
                        icon: Icon(tab.icon),
                        label: Text(tab.label),
                      );
                    }).toList(),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            ReceiveTab(),
                            SendTab(),
                            SyncSettingsPage(),
                            SettingsTab(),
                          ],
                        ),
                        if (_dragAndDropIndicator)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.file_download, size: 128),
                                const SizedBox(height: 30),
                                Text(t.sendTab.placeItems, style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: sizingInformation.isMobile
                ? NavigationBar(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    destinations: HomeTab.values.map((tab) {
                      return NavigationDestination(icon: Icon(tab.icon), label: tab.label);
                    }).toList(),
                  )
                : null,
          );
        },
      ),
    );
  }
}

/// Global pairing (PIN) dialog: shows the waiting state for an outgoing
/// request started with the heart button, and the confirm prompt for an
/// incoming request. Closes itself when the pairing state resolves
/// (accepted, declined, cancelled or timed out).
///
/// The dialog is closed from exactly one place: the state watcher below,
/// guarded by [_PairingDialogState._closing]. The action buttons only
/// update the pairing state and never pop themselves — popping in both
/// places closed the dialog twice and then popped the page underneath
/// it, leaving a black screen.
class _PairingDialog extends StatefulWidget {
  const _PairingDialog();

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  bool _closing = false;

  String _formatPin(String pin) => pin.length == 6 ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;

  @override
  Widget build(BuildContext context) {
    final isVi = Localizations.localeOf(context).languageCode == 'vi';
    return Consumer(
      builder: (context, ref) {
        final pairing = ref.watch(pairingProvider);
        final incoming = pairing.incoming;
        final outgoing = pairing.outgoing;
        if (incoming == null && outgoing == null) {
          if (!_closing) {
            _closing = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            });
          }
          return const SizedBox.shrink();
        }
        final pinStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 4);
        if (incoming != null) {
          return AlertDialog(
            title: Text(isVi ? 'Yêu cầu ghép cặp' : 'Pairing request'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isVi
                      ? '${incoming.sender.alias} muốn ghép cặp đồng bộ với thiết bị này.'
                      : '${incoming.sender.alias} wants to pair for sync with this device.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(_formatPin(incoming.pin), style: pinStyle),
                const SizedBox(height: 8),
                Text(
                  isVi
                      ? 'Chỉ chấp nhận nếu mã này giống mã đang hiện trên máy kia. Mã hết hạn sau 60 giây.'
                      : 'Only accept if this code matches the one shown on the other device. The code expires in 60 seconds.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                // No Navigator.pop here: clearing the pairing state
                // makes the watcher above close the dialog (once).
                onPressed: () async {
                  await ref.notifier(pairingProvider).declineIncoming();
                },
                child: Text(isVi ? 'Từ chối' : 'Decline'),
              ),
              FilledButton(
                onPressed: () async {
                  await ref.notifier(pairingProvider).acceptIncoming();
                },
                child: Text(isVi ? 'Chấp nhận' : 'Accept'),
              ),
            ],
          );
        }
        return AlertDialog(
          title: Text(isVi ? 'Ghép cặp thiết bị' : 'Pair this device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isVi ? 'Mã PIN ghép cặp với ${outgoing!.device.alias}:' : 'Pairing PIN for ${outgoing!.device.alias}:',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(_formatPin(outgoing.pin), style: pinStyle),
              const SizedBox(height: 8),
              Text(
                isVi
                    ? 'Đang chờ ${outgoing.device.alias} xác nhận mã này… (hết hạn sau 60 giây)'
                    : 'Waiting for ${outgoing.device.alias} to confirm this code… (expires in 60 seconds)',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              // No Navigator.pop here: clearing the pairing state
              // makes the watcher above close the dialog (once).
              onPressed: () {
                ref.notifier(pairingProvider).cancelOutgoing();
              },
              child: Text(isVi ? 'Huỷ' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }
}
