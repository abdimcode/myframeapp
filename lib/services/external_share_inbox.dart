import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'file_storage_manager.dart';
import 'package:crypto/crypto.dart';
import 'local_storage_service.dart';
import 'personal_gallery_store.dart';
import 'send_albums_store.dart';
import 'sync_pipeline.dart';

/// Local-only reception. No compression, cloud sync or frame calls may precede this.
class ExternalShareInbox {
  static final instance = ExternalShareInbox();
  Future<void> _tail = Future.value();
  static String keyFor(List<String> paths) {
    final sorted = [...paths]..sort();
    return sha256.convert(utf8.encode(jsonEncode(sorted))).toString();
  }

  Future<List<String>> persist(
    List<String> paths, {
    required String sessionId,
    required String playlistName,
  }) {
    final result = _tail.then((_) async {
      final storage = LocalStorageService.instance;
      final key = 'external_share_receipt_$sessionId';
      final previous = await storage.getString(key);
      if (previous != null) {
        return (jsonDecode(previous) as List).cast<String>();
      }
      final directory = await FileStorageManager.instance.imagesDir();
      final stableId = sha256.convert(utf8.encode(sessionId)).toString();
      final staged = <String>[];
      for (var i = 0; i < paths.length; i++) {
        final source = File(paths[i]);
        final suffix = p.extension(source.path);
        final target = File(
          p.join(directory.path, 'share_${stableId}_$i$suffix'),
        );
        if (!await target.exists()) {
          final temporary = File('${target.path}.part');
          await source.copy(temporary.path);
          await temporary.rename(target.path);
        }
        staged.add(target.path);
      }
      if (staged.length != paths.length) {
        throw StateError('Could not save every shared photo');
      }
      if (staged.length == 1) {
        await PersonalGalleryStore.instance.addPaths(staged);
      } else {
        // Multi-photo share = a PLAYLIST. Create the album AND self-heal any
        // earlier mis-ingestion of these same staged files from Personal.
        final albumId = 'share_$sessionId';
        await SendAlbumsStore.instance.createAlbum(
          playlistName,
          staged,
          sessionId: albumId,
        );
        await PersonalGalleryStore.instance.removePaths(staged);
        unawaited(SyncPipeline.instance.onAlbumsChanged(albumId: albumId));
      }
      await storage.setString(key, jsonEncode(staged));
      return staged;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
