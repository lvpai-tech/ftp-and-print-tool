import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_access.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/auto_upload/station_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/upload_folders.dart';
import 'package:lvpai_ftp_client/auto_upload/upload_slots.dart';
import 'package:lvpai_ftp_client/photo_normalizer.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:path/path.dart' as p;

import 'manual_batch_test.dart' as samples;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('识别结束照后先上报，队首仍在等待入库时结束照继续排队', () async {
    final fixture = await _QueueFixture.open();
    final uploader = fixture.uploader();
    await fixture.run(() async {
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await File(p.join(fixture.inbox.path, 'tourist.png'))
          .writeAsBytes(await _png());
      await _until(() => fixture.prepared.length == 1, '游客照开始上传');
      await samples.photo(fixture.inbox, 'ending', secret: 'ABCD12345678');
      await _until(() => fixture.notices.length == 1, '结束照提前上报');
      expect(fixture.prepared.length, 1);
      expect(fixture.notices.values.single, 'ABCD12345678');
      fixture.ingested.add(fixture.prepared.first);
      await _until(() => fixture.prepared.length == 2, '队首入库后结束照上传');
      expect(fixture.prepared.last, fixture.notices.keys.single);
    });
  });

  test('提前上报接口失败时仍正式上传结束照', () async {
    final fixture = await _QueueFixture.open();
    final uploader = fixture.uploader();
    fixture.rejectNotices = true;
    await fixture.run(() async {
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await samples.photo(fixture.inbox, 'ending', secret: 'ABCD12345678');
      await _until(
        () => uploader.jobs.singleOrNull?.state == 'accepted',
        '上报失败后的正式上传',
      );
      expect(fixture.noticeAttempts, greaterThan(0));
      expect(fixture.notices, isEmpty);
      expect(fixture.uploaded, contains(uploader.jobs.single.id));
    });
  });

  test('同一工作台两个机位分别上报结束照并恢复正式上传队列', () async {
    final fixture = await _QueueFixture.open();
    final peer = await fixture.addStation('20', 'c' * 64);
    final transferSlots = UploadSlots(1);
    final preparationSlots = UploadSlots(2);
    final support = Directory(p.join(fixture.scratch.path, 'workstation'));
    const store = ProfileStore();
    final inbox = Directory(p.join(support.path, 'inbox'));
    final folders = UploadFolders(
      store,
      inbox,
      Directory(p.join(support.path, 'auto-upload')),
    );
    StationUpload create(_QueueFixture target) => StationUpload(
      profile: target.profile,
      store: store,
      support: support,
      inboxRoot: inbox,
      folders: folders,
      folderAccess: FolderAccess(apple: false),
      settings: {'enabled': false, 'folderRequired': true},
      transferSlots: transferSlots,
      preparationSlots: preparationSlots,
    );
    final first = create(fixture);
    final second = create(peer);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await fixture.run(() async {
      // A20 在 A19 等入库期间仍能使用唯一传输名额。
      final firstFolder = await Directory(
        p.join(fixture.scratch.path, 'camera-a'),
      ).create();
      final secondFolder = await Directory(
        p.join(fixture.scratch.path, 'camera-b'),
      ).create();
      await Future.wait([
        first.changeFolder((path: firstFolder.path, bookmark: null)),
        second.changeFolder((path: secondFolder.path, bookmark: null)),
      ]);
      await Future.wait([first.setEnabled(true), second.setEnabled(true)]);
      expect(first.folder, isNot(second.folder));
      expect(first.uploader.running && second.uploader.running, isTrue);
      final bytes = await _png();
      Future<void> original(StationUpload station) async {
        await File(p.join(station.folder, 'original.png')).writeAsBytes(bytes);
      }

      await original(first);
      await _until(() => fixture.prepared.length == 1, '第一机位开始上传');
      await original(second);
      await _until(() => peer.prepared.length == 1, '第二机位开始上传');
      expect(fixture.prepared.single, peer.prepared.single);
      expect(
        first.uploader.jobs.single.snapshot,
        isNot(second.uploader.jobs.single.snapshot),
      );

      await Future.wait([
        samples.photo(
          Directory(first.folder),
          'ending',
          secret: 'ABCD12345678',
        ),
        samples.photo(
          Directory(second.folder),
          'ending',
          secret: 'WXYZ87654321',
        ),
      ]);
      await _until(
        () => fixture.notices.length == 1 && peer.notices.length == 1,
        '两个机位提前上报',
      );
      expect(fixture.notices.values.single, 'ABCD12345678');
      expect(peer.notices.values.single, 'WXYZ87654321');
      expect(fixture.prepared.length, 1);
      expect(peer.prepared.length, 1);

      await first.suspend();
      await first.resume();
      fixture.ingested.add(fixture.prepared.single);
      await _until(() => fixture.prepared.length == 2, '恢复第一机位的结束照上传');
      expect(peer.prepared.length, 1);
      peer.ingested.add(peer.prepared.single);
      await _until(() => peer.prepared.length == 2, '第二机位结束照上传');
      expect(fixture.prepared.last, fixture.notices.keys.single);
      expect(peer.prepared.last, peer.notices.keys.single);
      expect(fixture.noticeAttempts, 1);
      expect(peer.noticeAttempts, 1);
      await Future.wait([first.suspend(), second.suspend()]);
    });
  });

  test('旧机位保留原队列、存量识别基线和失败上报，传完才换目录', () async {
    final fixture = await _QueueFixture.open();
    final support = Directory(p.join(fixture.scratch.path, 'workstation'));
    final inboxRoot = Directory(p.join(support.path, 'inbox'));
    final newFolder = await Directory(
      p.join(fixture.scratch.path, 'camera-out'),
    ).create();
    final selection = (path: newFolder.path, bookmark: null);
    const store = ProfileStore();
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode(fixture.profile.toJson()),
      'ftp.watch.v1': jsonEncode({
        'folder': fixture.inbox.path,
        'recursive': true,
      }),
    });
    final previous = FolderUploader(
      storage: Directory(p.join(support.path, 'auto-upload')),
    );
    addTearDown(() async {
      await previous.stop();
      previous.dispose();
    });
    await fixture.run(() async {
      await samples.photo(fixture.inbox, 'stock', secret: 'STCK12345678');
      await previous.start(fixture.inbox, null, cosProfile: fixture.profile);
      await File(p.join(fixture.inbox.path, 'original.png'))
          .writeAsBytes(await _png());
      await _until(
        () => previous.jobs.singleOrNull?.state == 'accepted',
        '旧工作台原片确认',
      );
      final original = previous.jobs.single;
      fixture.rejectNotices = true;
      await samples.photo(fixture.inbox, 'ending', secret: 'ABCD12345678');
      await _until(() => fixture.noticeAttempts > 0, '旧工作台上报失败');
      expect(fixture.notices, isEmpty);
      await previous.stop();

      await store.migrateUploads(fixture.profile.api);
      final profile = (await store.loadStations(fixture.profile.api)).single;
      final station = StationUpload(
        profile: profile,
        store: store,
        support: support,
        inboxRoot: inboxRoot,
        transferSlots: UploadSlots(3),
        preparationSlots: UploadSlots(2),
        folderAccess: FolderAccess(apple: false),
        settings: await store.loadWatch(profile),
      );
      addTearDown(() async {
        await station.suspend();
        station.dispose();
      });
      await station.restore();
      expect(station.legacy, isTrue);
      expect(station.uploader.running, isFalse);
      fixture.rejectNotices = false;
      await station.setEnabled(true);
      expect(
        station.uploader.jobs
            .firstWhere((job) => job.id == original.id)
            .snapshot,
        original.snapshot,
      );
      await station.changeFolder(selection);
      expect(station.legacy, isTrue);
      await _until(() => fixture.notices.length == 1, '失败的结束照上报恢复');
      expect(fixture.notices.values.single, 'ABCD12345678');
      expect(fixture.prepared, [original.id]);
      fixture.ingested.add(original.id);
      await _until(() => fixture.prepared.length == 2, '旧目录结束照按序上传');
      expect(fixture.prepared.last, fixture.notices.keys.single);
      fixture.ingested.add(fixture.prepared.last);
      await _until(() => station.uploader.canFinishMigration, '旧队列全部入库');
      await station.changeFolder(selection);
      expect(station.legacy, isFalse);
      expect(station.folder, newFolder.path);
      expect(station.uploader.running, isFalse);
      expect(await store.loadWatch(profile), {
        'enabled': false,
        'folder': newFolder.path,
        'folderIdentity': await newFolder.resolveSymbolicLinks(),
        'recursive': true,
      });
      await station.setEnabled(true);
      expect(station.uploader.running, isTrue);
      expect(await File(original.source).exists(), isTrue);
      expect(fixture.prepared.length, 2);
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  final savedJpegSamples = Platform.environment['SAVED_JPEG_SAMPLE_DIR'];
  test('已保存的三张 JPG 按原发现顺序进入 COS 队列', () async {
    final fixture = await _QueueFixture.open();
    final uploader = fixture.uploader();
    final dimensions = [(2336, 5184), (1844, 4096), (2336, 5184)];
    await fixture.run(() async {
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      for (var index = 0; index < dimensions.length; index++) {
        final name = 'saved-${index + 1}.jpg';
        final original = await File(p.join(savedJpegSamples!, name))
            .readAsBytes();
        final source = await File(p.join(fixture.inbox.path, name))
            .writeAsBytes(original);
        await _until(
          () =>
              uploader.jobs.firstOrNull?.relative == name &&
              uploader.jobs.first.state == 'accepted',
          '$name 上传',
          describe: () => '${uploader.issues} ${uploader.orderWaitMessage}',
        );
        final job = uploader.jobs.first;
        expect(fixture.uploadedContentTypes[job.id], 'image/jpeg');
        fixture.ingested.add(job.id);
        await _until(
          () => job.state == 'ingested' && !File(job.snapshot).existsSync(),
          '$name 入库',
        );
        final preview = await job.readPhotoForReview();
        final info = img.JpegDecoder().startDecode(preview)!;
        expect((info.width, info.height), dimensions[index]);
        expect(await source.readAsBytes(), original);
      }
      expect(uploader.issues, isEmpty);
      expect(fixture.prepared, uploader.jobs.reversed.map((job) => job.id));
    });
  }, skip: savedJpegSamples == null);

  test('TIFF 收图按 JPEG 上传，归集后可从未改动的原件重建预览', () async {
    final fixture = await _QueueFixture.open();
    final image = img.Image(width: 160, height: 120);
    image.exif.imageIfd
      ..make = 'Camera brand'
      ..model = 'Camera model'
      ..[0x013b] = img.IfdValueAscii('PH-023');
    final original = img.encodeTiff(image);
    final source = await File(p.join(fixture.inbox.path, 'camera.TIFF'))
        .writeAsBytes(original);
    final uploader = fixture.uploader();
    await fixture.run(() async {
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      await _until(
        () => uploader.jobs.singleOrNull?.state == 'accepted',
        'TIFF 转换并上传',
        describe: () => '${uploader.issues} ${uploader.fatalError}',
      );
      final job = uploader.jobs.single;
      expect(job.relative, 'camera.jpg');
      expect(job.normalized, isTrue);
      final metadata = {
        'artist': 'PH-023',
        'cameraMake': 'Camera brand',
        'cameraModel': 'Camera model',
        'readStatus': 'READ',
      };
      expect(fixture.preparedExif[job.id], metadata);
      expect(
        AutoJob.fromJson(job.toJson()).captureMetadata?.toJson(),
        metadata,
      );
      expect(
        AutoJob.fromJson(job.toJson()..remove('captureMetadata'))
            .captureMetadata,
        isNull,
      );
      expect(fixture.uploadedContentTypes[job.id], 'image/jpeg');
      fixture.ingested.add(job.id);
      await _until(
        () => job.state == 'ingested' && !File(job.snapshot).existsSync(),
        '归集后清理快照',
      );
      final preview = await job.readPhotoForReview();
      expect(img.decodeJpg(preview)!.width, 160);
      expect(await source.readAsBytes(), original);
    });
  });

  final heifSample = Platform.environment['HEIF_SAMPLE'];
  test('HEIF 实际解码、保留拍摄时间并用 JPEG 提交 COS', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = Platform.isWindows
        ? TargetPlatform.windows
        : Platform.isMacOS
        ? TargetPlatform.macOS
        : TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final fixture = await _QueueFixture.open();
    final original = await File(heifSample!).readAsBytes();
    final converted = await normalizedCameraPhoto(original, 'camera.HIF');
    final source = await File(p.join(fixture.inbox.path, 'camera.HIF'))
        .writeAsBytes(original);
    final uploader = fixture.uploader();
    await fixture.run(() async {
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      await _until(
        () => uploader.jobs.singleOrNull?.state == 'accepted',
        'HEIF 转换并上传',
        describe: () =>
            '${uploader.issues} ${uploader.fatalError} ${uploader.orderWaitMessage}',
        timeout: const Duration(seconds: 25),
      );
      final job = uploader.jobs.single;
      expect(job.relative, 'camera.jpg');
      expect(AutoJob.fromJson(job.toJson()).normalized, isTrue);
      expect(fixture.uploadedContentTypes[job.id], 'image/jpeg');
      fixture.ingested.add(job.id);
      await _until(
        () => job.state == 'ingested' && !File(job.snapshot).existsSync(),
        '归集状态和待传副本清理',
      );
      final jpeg = await job.readPhotoForReview();
      expect(jpeg, converted);
      final info = img.JpegDecoder().startDecode(jpeg)!;
      expect((info.width, info.height), (4032, 3024));
      final metadata = img.decodeJpgExif(jpeg)!;
      expect(metadata.exifIfd[0x9003]?.toString(), '2018:03:30 12:14:19');
      expect(metadata.exifIfd[0x9291]?.toString(), '365');
      expect(metadata.imageIfd.orientation, 1);
      expect(img.decodePng((await job.readNormalizedThumbnail())!)!.width, 144);
      expect(await source.readAsBytes(), original);
    });
  }, skip: heifSample == null);

  final cameraSamples = Platform.environment['CAMERA_SAMPLE_DIR'];
  test('同拍 CR2 和 JPEG 只归集一张，拍摄时间不同则单独上传', () async {
    final fixture = await _QueueFixture.open();
    final uploader = fixture.uploader();
    final raw = await File(p.join(cameraSamples!, 'sample.cr2'))
        .copy(p.join(fixture.inbox.path, 'IMG_129.CR2'));
    final jpeg = File(p.join(fixture.inbox.path, 'IMG_129.JPG'));
    const captureTime = '2016:12:22 20:02:04';
    final cameraJpeg = img.Image(width: 160, height: 120);
    await fixture.run(() async {
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      await _until(
        () => uploader.jobs.singleOrNull?.state == 'accepted',
        'CR2 转换并上传',
        describe: () => '${uploader.issues} ${uploader.fatalError}',
        timeout: const Duration(seconds: 25),
      );
      final job = uploader.jobs.single;
      expect(job.source, raw.path);
      expect(job.captureTime, captureTime);
      expect(job.relative, 'IMG_129.jpg');
      expect(fixture.uploadedContentTypes[job.id], 'image/jpeg');
      fixture.ingested.add(job.id);
      await _until(() => job.state == 'ingested', '等待 RAW 入库');
      await uploader.stop();
      cameraJpeg.exif.exifIfd[0x9003] = img.IfdValueAscii(captureTime);
      await jpeg.writeAsBytes(img.encodeJpg(cameraJpeg));
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      await _until(() => uploader.settling == 1, '发现同拍 JPEG');
      await _until(() => uploader.settling == 0, '合并同拍 JPEG');
      expect(uploader.jobs, hasLength(1));
      expect(fixture.prepared, [job.id]);
      expect(
        img.JpegDecoder().startDecode(await job.readPhotoForReview()),
        isNotNull,
      );
      expect(await raw.length(), 11062629);

      cameraJpeg.exif.exifIfd[0x9003] = img.IfdValueAscii(
        '2016:12:22 20:02:05',
      );
      await jpeg.writeAsBytes(img.encodeJpg(cameraJpeg));
      await _until(() => uploader.jobs.length == 2, '不同拍摄时间的 JPEG');
    });
  }, skip: cameraSamples == null);

  final token = 'a' * 64;
  final requestId = 'b' * 64;
  const api = 'https://workstation.example';
  const stagingUrl = 'https://private.cos.ap-guangzhou.myqcloud.com/sample';

  test('workstation profile validates origin and keeps queue identity across token rotation', () {
    final profile = CosUploadProfile(api, '19', token);
    expect(CosUploadProfile.fromJson(profile.toJson()).queueTarget, '$api/19');
    expect(
      CosUploadProfile(api, '19', 'c' * 64).queueTarget,
      profile.queueTarget,
    );
    expect(
      () => CosUploadProfile('http://workstation.example', '19', token),
      throwsStateError,
    );
    expect(() => CosUploadProfile('$api/other', '19', token), throwsStateError);
    expect(() => CosUploadProfile(api, '0', token), throwsStateError);
  });

  test('PUT streams the exact bytes without the workstation token and retry confirms existing upload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = HttpClient();
    final local = _LocalTransport(transport, server.port);
    final scratch = await Directory.systemTemp.createTemp(
      'workstation-upload-test',
    );
    addTearDown(() async {
      transport.close(force: true);
      await server.close(force: true);
      await scratch.delete(recursive: true);
    });
    final file = File(p.join(scratch.path, 'raw.jpg'));
    final bytes = List<int>.generate(128 * 1024, (index) => index % 256);
    await file.writeAsBytes(bytes);
    var putCount = 0;
    var confirmCount = 0;
    final failures = <String>[];
    server.listen((request) async {
      final response = request.response;
      if (request.method == 'PUT') {
        putCount++;
        if (request.headers.value('X-Workstation-Token') != null) {
          failures.add('workstation token was sent to COS');
        }
        if (request.headers.value('x-cos-forbid-overwrite') != 'true' ||
            request.headers.value('x-cos-acl') != 'private' ||
            request.contentLength != bytes.length) {
          failures.add('required signed headers missing');
        }
        final received = await request.expand((c) => c).toList();
        if (received.length != bytes.length ||
            Iterable<int>.generate(bytes.length)
                .any((i) => received[i] != bytes[i])) {
          failures.add('body differs');
        }
        response.statusCode = putCount == 1 ? 200 : 409;
        await response.close();
        return;
      }
      if (request.headers.value('X-Workstation-Token') != token) {
        failures.add('authorization missing from business request');
      }
      final Map<String, Object> data;
      if (request.uri.path.endsWith('/confirm')) {
        confirmCount++;
        if (confirmCount == 1) {
          // Simulate the upload succeeding while its first business confirmation fails.
          response.statusCode = 503;
          await response.close();
          return;
        }
        data = {'status': 'QUEUED'};
      } else if (request.method == 'GET') {
        data = {'status': 'GROUPED'};
      } else {
        final requestData =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (requestData['requestId'] != requestId) {
          failures.add('request identity changed');
        }
        data = {
          'status': 'AWAITING_UPLOAD',
          'uploadUrl': stagingUrl,
          'uploadHeaders': {
            'Content-Length': '${bytes.length}',
            'Content-Type': 'image/jpeg',
            'x-cos-forbid-overwrite': 'true',
            'x-cos-acl': 'private',
          },
        };
      }
      response.write(jsonEncode({'code': 200, 'data': data}));
      await response.close();
    });

    await HttpOverrides.runZoned(() async {
      final client = CosUpload(CosUploadProfile(api, '19', token));
      addTearDown(client.close);
      final progress = <double>[];
      await expectLater(
        client.upload(file, requestId, 'd' * 64, progress.add),
        throwsStateError,
      );
      expect(
        await client.upload(
          file,
          requestId,
          'd' * 64,
          progress.add,
          recover: true,
        ),
        'QUEUED',
      );
      expect((await client.status(requestId)).status, 'GROUPED');
      expect(progress.last, 1.0);
    }, createHttpClient: (_) => local);
    expect(failures, isEmpty);
    expect(putCount, 1);
    expect(confirmCount, 2);
    expect(
      local.hosts,
      containsAll(['workstation.example', Uri.parse(stagingUrl).host]),
    );
  });

  test('慢写原片重启保序，重试和等待入库期间结束照不发送', () async {
    final fixture = await _QueueFixture.open();
    await fixture.run(() async {
      final uploader = fixture.uploader();
      final original = File(p.join(fixture.inbox.path, 'z-original.png'));
      final ending = File(p.join(fixture.inbox.path, 'a-ending.png'));
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await original.create();
      await _until(() => uploader.settling == 1, '发现原片');
      await ending.writeAsBytes(await _png());
      await _until(() => uploader.settling == 2, '发现结束照');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fixture.prepared, isEmpty);
      expect(uploader.orderWaitMessage, contains('z-original.png'));

      await uploader.stop();
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await original.delete();
      await _until(
        () => uploader.orderWaitMessage?.contains('请将原片放回') == true,
        '提示队首原片移走',
      );
      expect(fixture.prepared, isEmpty);
      fixture.failNextUpload = true;
      await original.writeAsBytes(await _png());
      await _until(
        () => uploader.jobs.any((job) => job.error.isNotEmpty),
        '首次传输失败并准备重试',
        describe: () =>
            '${uploader.issues} ${uploader.fatalError} ${fixture.prepared}',
      );
      final originalJob = uploader.jobs.singleWhere(
        (job) => job.source == original.path,
      );
      expect(fixture.prepared.toSet(), {originalJob.id});
      expect(uploader.orderWaitMessage, contains('等待重试'));

      await _until(
        () => originalJob.state == 'accepted',
        '原片 COS 受理',
        describe: () => '${originalJob.state} ${originalJob.error}',
      );
      await _until(
        () => fixture.statusQueries.contains(originalJob.id),
        '开始查询入库',
      );
      expect(fixture.prepared.toSet(), {originalJob.id});
      expect(uploader.orderWaitMessage, contains('等待服务端入库'));

      fixture.ingested.add(originalJob.id);
      await _until(() => fixture.prepared.toSet().length == 2, '放行结束照');
      expect(originalJob.state, 'ingested');
      expect(
        fixture.prepared.last,
        uploader.jobs.singleWhere((job) => job.source == ending.path).id,
      );
      await _until(() => fixture.uploaded.length == 2, '结束照上传成功');
    });
  });

  test('同次补扫没有发现顺序时须确认，确认结果重启后保留', () async {
    final fixture = await _QueueFixture.open();
    await fixture.run(() async {
      final uploader = fixture.uploader();
      final original = File(p.join(fixture.inbox.path, 'z-original.png'));
      final ending = File(p.join(fixture.inbox.path, 'a-ending.png'));
      final later = File(p.join(fixture.inbox.path, 'later.png'));
      await original.create();
      await ending.writeAsBytes(await _png());
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      expect(uploader.sourcesNeedingOrder.toSet(), {
        original.path,
        ending.path,
      });
      expect(uploader.waitingSources.keys, uploader.sourcesNeedingOrder);
      await later.writeAsBytes(await _png());
      await _until(
        () => uploader.waitingSources.containsKey(later.path),
        '发现后续照片',
      );
      expect(uploader.waitingSources.keys, [
        ...uploader.sourcesNeedingOrder,
        later.path,
      ]);
      expect(fixture.prepared, isEmpty);
      uploader.confirmNextSource(original.path);
      await _until(
        () => uploader.orderWaitMessage?.contains('z-original.png') == true,
        '确认原片优先',
      );
      await uploader.stop();
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      expect(uploader.sourcesNeedingOrder, isEmpty);
      expect(uploader.waitingSources.keys, [
        original.path,
        ending.path,
        later.path,
      ]);
      expect(uploader.orderWaitMessage, contains('z-original.png'));
      expect(fixture.prepared, isEmpty);
      final oldSignature = uploader.waitingSources[later.path];
      await expectLater(
        uploader.discardWaitingSource(later.path, 'stale'),
        throwsStateError,
      );
      expect(uploader.running, isTrue);
      await uploader.discardWaitingSource(later.path, oldSignature);
      expect(await later.exists(), isTrue);
      await uploader.stop();
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      expect(uploader.waitingSources.keys, [original.path, ending.path]);
      expect(fixture.prepared, isEmpty);
    });
  });
}

Future<void> _until(
  bool Function() condition,
  String description, {
  String Function()? describe,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待$description超时 ${describe?.call() ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(12, 12);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _QueueFixture {
  final HttpServer server;
  final Directory scratch, inbox;
  final transport = HttpClient();
  final prepared = <String>[];
  final notices = <String, String>{};
  final preparedExif = <String, Object?>{};
  final uploaded = <String>{};
  final uploadedContentTypes = <String, String?>{};
  final ingested = <String>{};
  final statusQueries = <String>{};
  final CosUploadProfile profile;
  final stations = <String, _QueueFixture>{};
  int noticeAttempts = 0;
  bool rejectNotices = false;
  bool failNextUpload = false;

  _QueueFixture(this.server, this.scratch, this.inbox, this.profile);

  static Future<_QueueFixture> open() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final scratch = await Directory.systemTemp.createTemp('workstation-queue-');
    final createdInbox = await Directory(p.join(scratch.path, 'inbox'))
        .create();
    final inbox = Directory(await createdInbox.resolveSymbolicLinks());
    final fixture = _QueueFixture(
      server,
      scratch,
      inbox,
      CosUploadProfile('https://workstation.example', '19', 'a' * 64),
    );
    fixture.stations['19'] = fixture;
    server.listen(fixture._handle);
    addTearDown(() async {
      fixture.transport.close(force: true);
      await server.close(force: true);
      await scratch.delete(recursive: true);
    });
    return fixture;
  }

  Future<_QueueFixture> addStation(String id, String token) async {
    final directory = await Directory(p.join(scratch.path, 'inbox-$id'))
        .create();
    final fixture = _QueueFixture(
      server,
      scratch,
      directory,
      CosUploadProfile(profile.api.origin, id, token),
    );
    stations[id] = fixture;
    addTearDown(() => fixture.transport.close(force: true));
    return fixture;
  }

  Future<void> run(Future<void> Function() body) => HttpOverrides.runZoned(
    body,
    createHttpClient: (_) =>
        _LocalTransport(transport, server.port, closeTransport: false),
  );

  FolderUploader uploader() {
    final uploader = FolderUploader(
      storage: Directory(p.join(scratch.path, 'state')),
      stableFor: const Duration(milliseconds: 80),
      scanInterval: const Duration(milliseconds: 30),
      retryDelay: const Duration(milliseconds: 300),
    );
    addTearDown(() async {
      await uploader.stop();
      uploader.dispose();
    });
    return uploader;
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final stationId = request.method == 'PUT' ? segments.first : segments[4];
    final station = stations[stationId];
    expect(station, isNotNull);
    await station!._handleStation(request);
  }

  Future<void> _handleStation(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'PUT') {
      await request.drain<void>();
      if (failNextUpload) {
        failNextUpload = false;
        response.statusCode = 503;
      } else {
        uploaded.add(request.uri.pathSegments.last);
        uploadedContentTypes[request.uri.pathSegments.last] = request.headers
            .value(HttpHeaders.contentTypeHeader);
      }
      await response.close();
      return;
    }

    expect(request.headers.value('X-Workstation-Token'), profile.token);
    final path = request.uri.path;
    final Map<String, Object> data;
    if (path.endsWith('/batch-notices')) {
      noticeAttempts++;
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      if (rejectNotices) {
        response.statusCode = 503;
        await response.close();
        return;
      }
      notices[payload['requestId'] as String] = payload['cardSecret'] as String;
      data = {'status': 'UPLOADING'};
    } else if (path.endsWith('/sessions')) {
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final id = payload['requestId'] as String;
      prepared.add(id);
      preparedExif[id] = payload['captureMetadata'];
      data = {
        'status': 'AWAITING_UPLOAD',
        'uploadUrl':
            'https://private.cos.ap-guangzhou.myqcloud.com/${profile.stationId}/$id',
        'uploadHeaders': {
          'Content-Length': '${payload['byteLength']}',
          'Content-Type': payload['contentType'],
          'x-cos-forbid-overwrite': 'true',
          'x-cos-acl': 'private',
        },
      };
    } else if (request.method == 'GET') {
      final id = request.uri.pathSegments.last;
      statusQueries.add(id);
      data = {'status': ingested.contains(id) ? 'INGESTED' : 'PROCESSING'};
    } else {
      final id = request.uri.pathSegments[request.uri.pathSegments.length - 2];
      data = {'status': uploaded.contains(id) ? 'QUEUED' : 'AWAITING_UPLOAD'};
    }
    response.write(jsonEncode({'code': 200, 'data': data}));
    await response.close();
  }
}

// Keeps the real Dart HTTP stream behavior and maps the two endpoints to a local fixture.
class _LocalTransport implements HttpClient {
  final HttpClient transport;
  final int port;
  final bool closeTransport;
  final hosts = <String>[];

  _LocalTransport(this.transport, this.port, {this.closeTransport = true});

  @override
  set connectionTimeout(Duration? timeout) =>
      transport.connectionTimeout = timeout;

  @override
  set idleTimeout(Duration timeout) => transport.idleTimeout = timeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    hosts.add(uri.host);
    return transport.openUrl(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  void close({bool force = false}) {
    if (closeTransport) transport.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
