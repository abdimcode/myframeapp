import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:myframe/widgets/push_progress_banner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:myframe/l10n/app_strings.dart';
import 'package:myframe/services/share_receiver_service.dart';
import 'package:myframe/services/external_share_inbox.dart';
import 'package:myframe/services/external_share_cast_service.dart';
import 'package:myframe/services/device_store.dart';
import 'package:myframe/services/personal_gallery_store.dart';
import 'package:myframe/services/send_albums_store.dart';
import 'package:myframe/services/upload_queue_controller.dart';
import 'package:myframe/services/external_share_queue.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<String> paths;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('myframe-share-test-');
    final bytes = img.encodeJpg(img.Image(width: 12, height: 16));
    paths = [];
    for (var i = 0; i < 3; i++) {
      final file = await File(
        '${directory.path}/image_$i.jpg',
      ).writeAsBytes(bytes);
      paths.add(file.path);
    }
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (_) async => true,
    );
  });
  tearDown(() async {
    UploadQueueController.instance.cancelTracking();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'cold/hot duplicate remains one batch after drain; separate shares stay separate',
    () {
      final receiver = ShareReceiverService.instance;
      final files = paths
          .map((p) => SharedMediaFile(path: p, type: SharedMediaType.image))
          .toList();
      receiver.enqueueShared(files);
      final batch = receiver.takePendingItems();
      expect(batch.length, 3);
      receiver.enqueueShared(files.reversed.toList());
      expect(receiver.hasPending, false);
      receiver.enqueueShared([
        SharedMediaFile(
          path: '${directory.path}/another.jpg',
          type: SharedMediaType.image,
        ),
      ]);
      expect(receiver.takePendingItems().length, 1);
      receiver.completeBatch(batch.first.sessionId);
      receiver.enqueueShared(files);
      expect(receiver.hasPending, false);
    },
  );

  test(
    'local single and batch persistence is idempotent across inbox instances',
    () async {
      final inbox = ExternalShareInbox();
      final single = await inbox.persist(
        [paths.first],
        sessionId: 'single',
        playlistName: 'Shared',
      );
      expect(PersonalGalleryStore.instance.paths, contains(single.single));
      final results = await Future.wait([
        inbox.persist(paths, sessionId: 'batch', playlistName: 'Shared'),
        inbox.persist(paths, sessionId: 'batch', playlistName: 'Shared'),
      ]);
      expect(results.first, results.last);
      expect(SendAlbumsStore.instance.albums.length, 1);
      expect(SendAlbumsStore.instance.albums.single.paths.length, 3);
      expect(PersonalGalleryStore.instance.paths.length, 1);
      await ExternalShareInbox().persist(
        paths,
        sessionId: 'batch',
        playlistName: 'Shared',
      );
      expect(SendAlbumsStore.instance.albums.length, 1);
      for (final path in results.first) {
        expect(await File(path).exists(), true);
        expect(path, isNot(isIn(paths)));
      }
    },
  );

  test(
    'one shared batch is locally visible before status and publishes exactly once',
    () async {
      final requests = <http.Request>[];
      final statusRequested = Completer<void>();
      final allowStatus = Completer<void>();
      var uploaded = 0;
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/status')) {
          if (!statusRequested.isCompleted) statusRequested.complete();
          await allowStatus.future;
          return http.Response(
            jsonEncode({
              'ok': true, 'online': true, 'status': 'online',
              'last_seen_ms': DateTime.now().millisecondsSinceEpoch,
              'online_grace_ms': 120000,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/upload')) {
          uploaded++;
          expect(
            utf8.decode(request.bodyBytes, allowMalformed: true),
            contains('name="silent"'),
          );
          return http.Response(
            jsonEncode({'ok': true, 'stored_path': '$uploaded.bin'}),
            200,
          );
        }
        if (request.url.path.endsWith('/slideshow')) {
          final body = jsonDecode(request.body) as Map;
          expect(body['imageIds'], ['1.bin', '2.bin', '3.bin']);
          expect(body['source'], 'playlist');
          return http.Response('{"ok":true}', 200);
        }
        throw StateError('Unexpected request ${request.url}');
      });
      const frame = PairedFrame(
        deviceId: 'D0CF13E03618',
        wifiSsid: 'Home',
        frameName: 'Living room',
        apiUrl: 'https://myframe.ink',
      );
      await http.runWithClient(() async {
        final service = ExternalShareCastService.instance;
        final first = service.castToFrames(
          paths: paths,
          frames: [frame],
          authToken: '',
          strings: AppStrings.current,
          sessionId: 'dispatch',
        );
        final duplicate = service.castToFrames(
          paths: paths,
          frames: [frame],
          authToken: '',
          strings: AppStrings.current,
          sessionId: 'dispatch',
        );
        await statusRequested.future;
        expect(SendAlbumsStore.instance.albums.length, 1);
        expect(SendAlbumsStore.instance.albums.single.paths.length, 3);
        expect(uploaded, 0);
        allowStatus.complete();
        final results = await Future.wait([first, duplicate]);
        expect(results.first.sent, 3);
        expect(results.last.sent, 3);
      }, () => client);
      expect(uploaded, 3);
      expect(
        requests.where((r) => r.url.path.endsWith('/slideshow')).length,
        1,
      );
      expect(requests.where((r) => r.url.path.endsWith('/push')), isEmpty);
    },
  );

  test(
    'offline retry retains successful image IDs and emits one complete playlist',
    () async {
      final queue = ExternalShareQueue.instance;
      final entry = QueuedExternalShare(
        id: 'retry-batch',
        paths: paths,
        uploadedIds: ['already.bin'],
        uploadTargets: ['D0CF13E03618'],
        baseUrl: 'https://myframe.ink',
        pairingToken: null,
        authToken: '',
        macSlug: 'D0CF13E03618',
        displaySeconds: 600,
        intervalMinutes: 10,
        strategy: 1,
        durationHours: 6,
        createdAtMs: 1,
      );
      await Future.wait([queue.enqueue(entry), queue.enqueue(entry)]);
      expect(await queue.pendingCount(), 1);
      var uploaded = 0;
      var published = 0;
      await http.runWithClient(
        () async {
          expect(await queue.flush(), 1);
          expect(await queue.flush(), 0);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/upload')) {
            uploaded++;
            return http.Response(
              jsonEncode({'ok': true, 'stored_path': '$uploaded.bin'}),
              200,
            );
          }
          if (request.url.path.endsWith('/slideshow')) {
            published++;
            expect((jsonDecode(request.body) as Map)['imageIds'], [
              'already.bin',
              '1.bin',
              '2.bin',
            ]);
            return http.Response('{"ok":true}', 200);
          }
          throw StateError('Unexpected request');
        }),
      );
      expect(uploaded, 2);
      expect(published, 1);
      expect(await queue.pendingCount(), 0);
    },
  );

  test(
    'ambiguous playlist POST is retained without automatic redispatch',
    () async {
      final queue = ExternalShareQueue.instance;
      await queue.enqueue(
        QueuedExternalShare(
          id: 'uncertain',
          paths: paths,
          uploadedIds: ['1.bin', '2.bin', '3.bin'],
          uploadTargets: ['D0CF13E03618'],
          baseUrl: 'https://myframe.ink',
          pairingToken: null,
          authToken: '',
          macSlug: 'D0CF13E03618',
          displaySeconds: 600,
          intervalMinutes: 10,
          strategy: 1,
          durationHours: 6,
          createdAtMs: 1,
        ),
      );
      var posts = 0;
      await http.runWithClient(
        () async {
          expect(await queue.flush(), 0);
          expect(await queue.flush(), 0);
        },
        () => MockClient((request) async {
          posts++;
          throw TimeoutException(
            'Response lost after server accepted the batch',
          );
        }),
      );
      expect(posts, 1);
      expect(await queue.pendingCount(), 1);
    },
  );

  testWidgets('global capsule leaves the current navigator route in place', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => PushProgressOverlay(child: child!),
        home: const Scaffold(body: Text('Home route')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Current details route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final queue = UploadQueueController.instance;
    queue.beginShare('route', 'Uploading shared photo…');
    await tester.pump();
    expect(find.text('Current details route'), findsOneWidget);
    expect(find.text('Uploading shared photo…'), findsOneWidget);
    expect(navigator.currentState!.canPop(), true);
    queue.finishShare('route');
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Current details route'), findsOneWidget);
    expect(find.text('Uploading shared photo…'), findsNothing);
  });

  testWidgets(
    'shared upload capsule state completes and clears after three seconds',
    (tester) async {
      final queue = UploadQueueController.instance;
      queue.beginShare('one', 'Uploading shared photo…');
      queue.updateShare('one', .4, 'Uploading shared photo…');
      expect(queue.currentJob!.progress, .4);
      queue.finishShare('one');
      expect(queue.currentJob!.stage, PushJobStage.completed);
      expect(queue.currentJob!.progress, 1);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(queue.currentJob, isNotNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(queue.currentJob, isNull);
    },
  );
}
