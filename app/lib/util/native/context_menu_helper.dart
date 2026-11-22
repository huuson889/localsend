import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ContextMenuHelper');

Future<bool> enableContextMenu() async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return false;
  }

  try {
    final String script =
        '''
\$TargetPath = "${Platform.resolvedExecutable}"
\$ShortcutFile = "${_getWindowsFilePath(_windowsFileName)}"
\$WScriptShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WScriptShell.CreateShortcut(\$ShortcutFile)
\$Shortcut.TargetPath = \$TargetPath
\$Shortcut.Save()
''';
    final result = await Process.run('powershell', ['-Command', script]);
    if (result.stderr != null && result.stderr!.isNotEmpty) {
      throw Exception('Failed to create shortcut: ${result.stderr}');
    }
    // Also register the classic Explorer verb ("Send with LocalSend"
    // directly in the right-click menu; under "Show more options" on
    // Windows 11). The SendTo shortcut above stays available as well.
    await _registerExplorerMenu();
    return await File(_getWindowsFilePath(_windowsFileName)).exists();
  } catch (e) {
    _logger.severe('Failed to enable context menu: $e');
    return false;
  }
}

Future<bool> disableContextMenu() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        final file = File(_getWindowsFilePath(_windowsFileName));
        if (await file.exists()) {
          await file.delete();
        }
        await _unregisterExplorerMenu();
        return true;
      default:
        return false;
    }
  } catch (e) {
    return false;
  }
}

Future<bool> isContextMenuEnabled() async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return await File(_getWindowsFilePath(_windowsFileName)).exists();
    default:
      return false;
  }
}

const _windowsFileName = 'LocalSend';

String _getWindowsFilePath(String appName) {
  final appData = Platform.environment['APPDATA'];
  return '$appData/Microsoft/Windows/SendTo/$appName.lnk';
}

/// Registry keys of the classic Explorer context-menu verb (files and
/// folders). HKCU needs no admin rights, and [disableContextMenu] removes
/// the keys again.
const _explorerMenuKeys = [
  r'Software\Classes\*\shell\LocalSend',
  r'Software\Classes\Directory\shell\LocalSend',
];

/// Adds "Send with LocalSend" to the classic Explorer right-click menu.
/// The app already handles file paths passed as process arguments (see
/// `LoadSelectionFromArgsAction`), including directories; repeated
/// invocations are bunched into the already running instance, so selecting
/// several files in Explorer sends them all.
Future<void> _registerExplorerMenu() async {
  final exe = Platform.resolvedExecutable;
  for (final key in _explorerMenuKeys) {
    await Process.run('reg', ['add', 'HKCU\\$key', '/ve', '/d', 'Send with LocalSend', '/f']);
    await Process.run('reg', ['add', 'HKCU\\$key', '/v', 'Icon', '/d', '$exe,0', '/f']);
    await Process.run('reg', ['add', 'HKCU\\$key\\command', '/ve', '/d', '"$exe" "%1"', '/f']);
  }
}

Future<void> _unregisterExplorerMenu() async {
  for (final key in _explorerMenuKeys) {
    await Process.run('reg', ['delete', 'HKCU\\$key', '/f']);
  }
}
