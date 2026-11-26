import 'package:flutter/material.dart';
import 'package:routerino/routerino.dart';

/// Shows a short toast (snackbar) for a paired-sync event.
///
/// Unlike `showSnackBar` in `snackbar.dart`, this does not remove the current
/// snackbar, so a "started" toast and the following "finished" toast are both
/// shown (queued) instead of the second one replacing the first instantly.
///
/// Sync services also run while the app is in the tray/background where there
/// may be no usable scaffold: failures to show are swallowed on purpose.
void showSyncToast(String message) {
  try {
    ScaffoldMessenger.of(Routerino.context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (_) {
    // No UI available (e.g. app not started yet): the toast is best-effort.
  }
}

/// Shows a paired-sync toast in Vietnamese when the app language is
/// Vietnamese, in English otherwise (same convention as the sync settings page).
void showSyncToastLocalized({required String en, required String vi}) {
  var message = en;
  try {
    if (Localizations.localeOf(Routerino.context).languageCode == 'vi') {
      message = vi;
    }
  } catch (_) {
    // Fall back to English.
  }
  showSyncToast(message);
}
