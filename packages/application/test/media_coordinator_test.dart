import 'dart:async';
import 'dart:io';

import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:test/test.dart';

final class FakeEngine implements DownloadEngine {
  final controllers = <String, StreamController<EngineEvent>>{};
  final started = <String>[];

  @override
  String get providerId => 'engine.fake';
  @override
  int get apiVersion => 1;
  @override
  Future<EngineCapabilities> capabilities() async =>
      EngineCapabilities(
          segmentedDownload: true,
          dynamicConnections: false,
          resume: true,
          customHeaders: true,
          cookies: true,
          referer: true,
          proxy: false,
          speedLimit: false,
          http2: false,
          ftp: false,
          torrent: false);
  @override
  Future<ProbeResult> probe(DownloadRequest r) async =>
      const ProbeResult(supported: true);
  @override
  Future<EngineTaskHandle> create(
      TaskId id, DownloadRequest r) async {
    controllers[id.value] = StreamController<EngineEvent>();
    return EngineTaskHandle(engineTaskId: id.value);
  }
  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    // Write the output file and complete immediately.
    controllers[id.value]!.add(
        EngineCompleted(outputPath: _lastOutput));
  }
  String? _lastOutput;
  @override
  Future<void> pause(TaskId id) async {}
  @override
  Future<void> resume(TaskId id) async {}
  @override
  Future<void> cancel(TaskId id) async {}
  @override
  Future<void> checkpoint(TaskId id) async {}
  @override
  Future<void> replaceSource(TaskId id, DownloadRequest r) async {}
  @override
  Future<void> setSpeedLimit(TaskId id, int? b) async {}
  @override
  Stream<EngineEvent> events(TaskId id) => controllers[id.value]!.stream;
}

final class FakeResolver implements MediaResolver {
  FakeResolver(this.planToReturn);
  final MediaPlan planToReturn;
  @override
  String get providerId => 'media.fake';
  @override
  int get apiVersion => 1;
  @override
  Future<MediaProbe> probe(String url,
          {Map<String, String> headers = const {}, String? cookieRef}) async =>
      const MediaProbe(supported: true, title: 't');
  @override
  Future<MediaPlan> plan(MediaSelection s,
          {Map<String, String> headers = const {}}) async =>
      planToReturn;
  @override
  Future<String> version() async => 'fake';
}

final class FakeMuxer implements MediaMuxer {
  final muxed = <MuxStep>[];
  bool fail = false;
  @override
  String get providerId => 'media.ffmpeg-fake';
  @override
  Future<MuxResult> mux(MuxStep step, {String? workDir}) async {
    muxed.add(step);
    if (fail) return const MuxResult(ok: false, error: 'ffmpeg died');
    final out =
        '${workDir ?? '.'}${Platform.pathSeparator}${step.outputFileName}';
    await File(out).writeAsBytes([1, 2, 3]);
    return MuxResult(ok: true, outputPath: out);
  }
  @override
  Future<MuxResult> attachSubtitles(String v, List<String> subs,
          {String? outputPath}) async =>
      MuxResult(ok: true, outputPath: outputPath ?? v);
  @override
  Future<String> version() async => 'fake';
}

final class FakeDownloader implements ComponentDownloader {
  var calls = 0;
  @override
  String get componentId => 'tool.ytdlp';
  @override
  Future<int> download(
      {required String pageUrl,
      required String outputPath,
      String? formatId,
      Map<String, String> headers = const {},
      List<String> subtitleLangs = const [],
      void Function(double)? onProgress}) async {
    calls++;
    onProgress?.call(1.0);
    await File(outputPath).writeAsBytes([9]);
    return 0;
  }
}

void main() {
  late Directory dir;
  late JsonTaskRepository repo;
  late InMemoryEventBus bus;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('freedm-media');
    repo = await JsonTaskRepository.open(dir);
    bus = InMemoryEventBus();
  });
  tearDown(() async {
    await bus.close();
    await repo.pending;
    for (var i = 0; i < 20; i++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await repo.pending;
      }
    }
  });

  Future<DownloadTask> waitFor(MediaDownloadCoordinator mc, TaskId id,
      DownloadStatus status) async {
    final c = Completer<DownloadTask>();
    final sub = mc.changes.listen((t) {
      if (t.id == id && t.status == status && !c.isCompleted) {
        c.complete(t);
      }
    });
    final cur = mc.task(id);
    if (cur != null && cur.status == status) c.complete(cur);
    final t = await c.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    return t;
  }

  test('engine step → mux → completed; artifacts tracked', () async {
    final engine = FakeEngine();
    final muxer = FakeMuxer();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'out.mkv',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4', role: 'video'),
          EngineDownloadStep(
              url: 'http://x/a', outputFileName: 'a.m4a', role: 'audio'),
          MuxStep(
              inputs: ['v.mp4', 'a.m4a'], outputFileName: 'out.mkv'),
        ],
      )),
      muxer: muxer,
    );
    engine._lastOutput = '${dir.path}/work/v.mp4';

    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://youtube.com/watch?v=x'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    final done =
        await waitFor(mc, t.id, DownloadStatus.completed);
    expect(done.status, DownloadStatus.completed);
    expect(muxer.muxed.single.inputs, ['v.mp4', 'a.m4a']);
    await mc.dispose();
  });

  test('component step runs registered downloader', () async {
    final engine = FakeEngine();
    final dl = FakeDownloader();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          ComponentDownloadStep(
              componentId: 'tool.ytdlp', outputFileName: 'v.mp4'),
        ],
      )),
      muxer: FakeMuxer(),
      componentDownloaders: {'tool.ytdlp': dl},
    );
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/watch'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    await waitFor(mc, t.id, DownloadStatus.completed);
    expect(dl.calls, 1);
    await mc.dispose();
  });

  test('mux failure fails the task', () async {
    final engine = FakeEngine();
    final muxer = FakeMuxer()..fail = true;
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'o.mkv',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4', role: 'video'),
          MuxStep(inputs: ['v.mp4'], outputFileName: 'o.mkv'),
        ],
      )),
      muxer: muxer,
    );
    engine._lastOutput = '${dir.path}/work/v.mp4';
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/w'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    final done = await waitFor(mc, t.id, DownloadStatus.failed);
    expect(done.lastError, ErrorCode.unknown);
    await mc.dispose();
  });

  test('missing component downloader fails cleanly', () async {
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          ComponentDownloadStep(
              componentId: 'tool.missing', outputFileName: 'v.mp4'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/w'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    await waitFor(mc, t.id, DownloadStatus.failed);
    await mc.dispose();
  });
}
