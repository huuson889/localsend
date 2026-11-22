import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

part 'android_channel.mapper.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/localsend');
final _logger = Logger('AndroidSaf');

/// From Android 10 and above, we need to use the Storage Access Framework (SAF) to access files due to the scoped storage.
/// SAF itself is available from Android 4.4 (API level 19).
/// We implemented our own algorithm to build encode and decode content URIs.
/// Older versions might also work but the encoded content URI is not guaranteed to work with our algorithm.
const contentUriMinSdk = 27;

Future<PickDirectoryResult?> pickDirectoryAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('pickDirectory');
  if (result == null) {
    return null;
  }

  return PickDirectoryResultMapper.fromJson({
    'directoryUri': result['directoryUri'],
    'files': (result['files'] as List).map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList(),
  });
}

Future<String?> pickDirectoryPathAndroid() async {
  final result = await _methodChannel.invokeMethod<String>('pickDirectoryPath');
  return result;
}

/// One file inside an Android SAF directory tree.
class SafDirectoryFile {
  /// Path relative to the picked directory, using `/` separators.
  final String relativePath;

  /// Content URI that can be opened for reading.
  final String uri;
  final int size;

  /// Last modification time in milliseconds since epoch, if the provider knows it.
  final int? lastModifiedMillis;

  const SafDirectoryFile({
    required this.relativePath,
    required this.uri,
    required this.size,
    required this.lastModifiedMillis,
  });

  String? get lastModifiedRfc3339 {
    final millis = lastModifiedMillis;
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();
  }
}

/// Lists all files below the SAF directory [treeUri] (recursive).
/// Used by folder sync: the picked sync folder is a `content://` tree URI,
/// which `dart:io` cannot scan directly.
Future<List<SafDirectoryFile>> listDirectoryFilesAndroid(String treeUri) async {
  final result = await _methodChannel.invokeMethod<List>('listDirectoryFiles', {
    'treeUri': treeUri,
  });
  if (result == null) {
    return const [];
  }
  return result.map((entry) {
    final map = (entry as Map).cast<String, dynamic>();
    return SafDirectoryFile(
      relativePath: map['relativePath'] as String,
      uri: map['uri'] as String,
      size: (map['size'] as num).toInt(),
      lastModifiedMillis: (map['lastModified'] as num?)?.toInt(),
    );
  }).toList();
}

/// Reads the current clipboard image on Android.
///
/// The `pasteboard` plugin only sees image URIs on some devices and its
/// write side is unreliable, so paired sync uses the app channel instead.
Future<Uint8List?> getClipboardImageAndroid() async {
  return await _methodChannel.invokeMethod<Uint8List>('getClipboardImage');
}

/// Writes [bytes] to the Android clipboard as an image.
Future<void> writeClipboardImageAndroid(Uint8List bytes) async {
  await _methodChannel.invokeMethod<void>('writeClipboardImage', bytes);
}

Future<List<FileInfo>?> pickFilesAndroid() async {
  final result = await _methodChannel.invokeMethod<List>('pickFiles');
  if (result == null) {
    return null;
  }

  return result.map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList();
}

/// Returns the global "Download" directory, e.g. /storage/emulated/0/Download.
Future<String?> getDownloadsDirectoryAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDownloadsDirectory');
  } catch (e) {
    _logger.warning('Could not get downloads directory', e);
    return null;
  }
}

Future<bool> getSystemAnimationsStatusAndroid() async {
  return await _methodChannel.invokeMethod('isAnimationsEnabled') ?? true;
}

/// Requests the "Nearby devices" permission gating local network access on Android 17+.
/// Returns true when granted or when running on an older Android version.
Future<bool> requestLocalNetworkPermissionAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>('requestLocalNetworkPermission') ?? false;
  } catch (e) {
    _logger.warning('Could not request local network permission', e);
    return false;
  }
}

Future<void> openContentUri({
  required String uri,
}) async {
  _logger.info('Opening content URI: $uri');
  await _methodChannel.invokeMethod('openContentUri', {
    'uri': uri,
  });
}

/// Tells MainActivity that the Dart side is now subscribed to the share_handler media stream,
/// so share intents that were held back during app start can be replayed.
Future<void> flushPendingShareIntentsAndroid() async {
  try {
    await _methodChannel.invokeMethod('shareIntentReady');
  } catch (e) {
    _logger.warning('Could not flush pending share intents', e);
  }
}

Future<void> openGallery() async {
  _logger.info('Opening gallery');
  await _methodChannel.invokeMethod('openGallery');
}

@MappableClass()
class PickDirectoryResult with PickDirectoryResultMappable {
  final String directoryUri;
  final List<FileInfo> files;

  PickDirectoryResult({
    required this.directoryUri,
    required this.files,
  });
}

@MappableClass()
class FileInfo with FileInfoMappable {
  final String name;
  final int size;
  final String uri;

  /// RFC 3339 in UTC. Null when the document provider does not know it.
  final String? lastModified;

  FileInfo({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
  });
}
