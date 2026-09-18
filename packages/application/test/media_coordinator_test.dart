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
  final requests = <String, DownloadRequest>{};

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
    // Broadcast like the real adapter — a paused engine step
    // re-subscribes on resume.
    controllers[id.value] = StreamController<EngineEvent>.broadcast();
    requests[id.value] = r;
    return EngineTaskHandle(engineTaskId: id.value);
  }
  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    // Write the output file and complete immediately — the deliver
    // stage copies produced.last, so the fake artifact must exist.
    // Default lands under the request's target dir (= the task's
    // private workDir) so deliver/rename exercises a real file.
    final out = _lastOutput ??
        (requests[id.value] != null
            ? '${requests[id.value]!.output.targetDirectory}'
                '${Platform.pathSeparator}${id.value}.bin'
            : null);
    if (out != null) {
      final f = File(out);
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1]);
    }
    controllers[id.value]!.add(EngineCompleted(outputPath: out));
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
  bool isKnown(TaskId id) => controllers.containsKey(id.value);
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

  /// Simulates yt-dlp's `%(ext)s` — writes `outputPath + extSuffix`
  /// instead of outputPath itself (real yt-dlp appends the
  /// container ext to a bare -o name).
  String? extSuffix;
  @override
  String get componentId => 'tool.ytdlp';
  @override
  Future<int> download(
      {required String pageUrl,
      required String outputPath,
      String? formatId,
      Map<String, String> headers = const {},
      List<String> subtitleLangs = const [],
      CancellationToken? cancel,
      void Function(double)? onProgress}) async {
    calls++;
    onProgress?.call(1.0);
    await File(outputPath + (extSuffix ?? '')).writeAsBytes([9]);
    return 0;
  }
}

/// Engine whose start never finishes on its own — pause emits
/// EnginePaused (the real engine's pause acknowledgement) and
/// resume completes the step. Guards the pause-in-place →
/// engine.resume path: a re-create would re-probe the URL.
final class PausableEngine extends FakeEngine {
  final pausedIds = <String>[];
  final resumed = <String>[];
  final startedGate = Completer<void>();
  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    if (!startedGate.isCompleted) startedGate.complete();
  }
  @override
  Future<void> pause(TaskId id) async {
    pausedIds.add(id.value);
    controllers[id.value]!.add(const EnginePaused());
  }
  @override
  Future<void> resume(TaskId id) async {
    resumed.add(id.value);
    // Write the artifact — delivery renames produced.last into the
    // target dir, so a missing file fails the task.
    final out = _lastOutput!;
    await File(out).parent.create(recursive: true);
    await File(out).writeAsBytes([1, 2, 3]);
    controllers[id.value]!.add(EngineCompleted(outputPath: out));
  }
}

/// First call blocks until its CancellationToken fires (mimicking
/// yt-dlp killed mid-run); the second call "resumes" and completes.
final class PausableDownloader implements ComponentDownloader {
  var calls = 0;
  final started = Completer<void>();
  @override
  String get componentId => 'tool.ytdlp';
  @override
  Future<int> download(
      {required String pageUrl,
      required String outputPath,
      String? formatId,
      Map<String, String> headers = const {},
      List<String> subtitleLangs = const [],
      CancellationToken? cancel,
      void Function(double)? onProgress}) async {
    calls++;
    if (calls == 1) {
      if (!started.isCompleted) started.complete();
      await cancel?.onCancelled;
      return cancelledExitCode;
    }
    await File(outputPath).writeAsBytes([9]);
    return 0;
  }
}

/// start() parks on [gate] — opens the cancel-during-engine-start
/// window the coordinator's post-start guard exists to close.
final class GatedStartEngine extends FakeEngine {
  final gate = Completer<void>();
  final cancelled = <String>[];
  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    await gate.future;
  }
  @override
  Future<void> cancel(TaskId id) async {
    cancelled.add(id.value);
  }
}

/// Mux that blocks until [release] — lets a test request a pause
/// while the task sits in `muxing`, which has no direct `pausing`
/// edge in the base table.
final class BlockingMuxer extends FakeMuxer {
  final started = Completer<void>();
  final _release = Completer<void>();
  void release() {
    if (!_release.isCompleted) _release.complete();
  }
  @override
  Future<MuxResult> mux(MuxStep step, {String? workDir}) async {
    muxed.add(step);
    if (!started.isCompleted) started.complete();
    await _release.future;
    final out =
        '${workDir ?? '.'}${Platform.pathSeparator}${step.outputFileName}';
    await File(out).writeAsBytes([1, 2, 3]);
    return MuxResult(ok: true, outputPath: out);
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
    // Generous bound — the suite runs test files in parallel and a
    // loaded box can stretch the resolve→steps→deliver chain well
    // past a few seconds without anything being wrong.
    final t = await c.future.timeout(const Duration(seconds: 20));
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

  test('component step pause → resume re-invokes and completes',
      () async {
    final dl = PausableDownloader();
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
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
    // Wait until the step is actually running, then pause it.
    await dl.started.future.timeout(const Duration(seconds: 5));
    await mc.pause(t.id);
    final parked = await waitFor(mc, t.id, DownloadStatus.paused);
    expect(parked.status, DownloadStatus.paused);

    await mc.resume(t.id);
    final done = await waitFor(mc, t.id, DownloadStatus.completed);
    expect(done.status, DownloadStatus.completed);
    expect(dl.calls, 2); // resume re-ran the same step
    await mc.dispose();
  });

  test('component step with a bare output name delivers the '
      'resolved container extension', () async {
    // Real yt-dlp writes <name>.<container-ext> for a bare -o path
    // — the coordinator must resolve that sibling artifact or the
    // delivered file lands extensionless and won't open.
    final dl = FakeDownloader()..extSuffix = '.mkv';
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v', // bare — ext decided by the producer
        steps: [
          ComponentDownloadStep(
              componentId: 'tool.ytdlp', outputFileName: 'v'),
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
    expect(File('${dir.path}/v.mkv').existsSync(), isTrue);
    expect(File('${dir.path}/v').existsSync(), isFalse);
    await mc.dispose();
  });

  test('engine step pause → resume calls engine.resume, not create',
      () async {
    final engine = PausableEngine();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4', role: 'video'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    engine._lastOutput = '${dir.path}/work/v.mp4';
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/watch'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    await engine.startedGate.future
        .timeout(const Duration(seconds: 5));
    await mc.pause(t.id);
    final parked = await waitFor(mc, t.id, DownloadStatus.paused);
    expect(parked.status, DownloadStatus.paused);

    await mc.resume(t.id);
    final done = await waitFor(mc, t.id, DownloadStatus.completed);
    expect(done.status, DownloadStatus.completed);
    // The paused engine task was resumed in place — a second
    // create would have re-probed the URL and reset its item.
    expect(engine.resumed, [t.id.value]);
    expect(engine.started, [t.id.value]);
    await mc.dispose();
  });

  test('cancel during engine start stops the just-started step',
      () async {
    final engine = GatedStartEngine();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4', role: 'video'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/watch'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    // Wait until engine.start is actually in flight on the gate.
    for (var i = 0; i < 100 && engine.started.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(engine.started, contains(t.id.value));

    await mc.cancel(t.id);
    await waitFor(mc, t.id, DownloadStatus.cancelled);

    // Release the start — without the post-start guard the engine
    // task would keep downloading into workDir, untracked.
    engine.gate.complete();
    for (var i = 0; i < 100 && engine.cancelled.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(engine.cancelled.length, greaterThanOrEqualTo(2),
        reason: 'user cancel + post-start guard cancel expected');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mc.task(t.id)!.status, DownloadStatus.cancelled);
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

  test('pause during mux parks at the next step boundary, '
      'resume continues', () async {
    // A plan with a download step after mux: pausing mid-mux must
    // wait out the stage and park BEFORE the next step runs —
    // muxing→pausing is a legal edge (InvalidTransitionError would
    // otherwise leave the task stuck non-terminal).
    final engine = FakeEngine();
    final muxer = BlockingMuxer();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'o.mkv',
        steps: [
          MuxStep(inputs: ['v.mp4'], outputFileName: 'o.mkv'),
          EngineDownloadStep(
              url: 'http://x/a', outputFileName: 'a.m4a',
              role: 'audio'),
        ],
      )),
      muxer: muxer,
    );
    engine._lastOutput = '${dir.path}/work/a.m4a';
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/m'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    await muxer.started.future.timeout(const Duration(seconds: 5));
    await mc.pause(t.id); // mid-mux: must land at the boundary
    muxer.release();
    final parked = await waitFor(mc, t.id, DownloadStatus.paused);
    expect(parked.status, DownloadStatus.paused);
    // The boundary parked BEFORE the audio step ran.
    expect(engine.started, isEmpty);
    await mc.resume(t.id);
    await waitFor(mc, t.id, DownloadStatus.completed);
    expect(engine.started, [t.id.value]);
    await mc.dispose();
  });

  test('remove on a paused task cancels then deletes the record',
      () async {
    final dl = PausableDownloader();
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
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
    await dl.started.future.timeout(const Duration(seconds: 5));
    await mc.pause(t.id);
    await waitFor(mc, t.id, DownloadStatus.paused);

    await mc.remove(t.id);
    // Gone from memory AND the repo — listActive includes paused,
    // so a retained record would resurface as failed on recover().
    expect(mc.task(t.id), isNull);
    expect(await repo.listActive(), isEmpty);
    await mc.dispose();
  });

  test('remove on a completed task deletes its record', () async {
    final engine = FakeEngine();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4',
              role: 'video'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    engine._lastOutput = '${dir.path}/work/v.mp4';
    final t = await mc.enqueueMedia(
      const MediaSelection(pageUrl: 'https://x/watch'),
      workDir: '${dir.path}/work',
      targetDirectory: dir.path,
    );
    await waitFor(mc, t.id, DownloadStatus.completed);
    await mc.remove(t.id);
    expect(mc.task(t.id), isNull);
    expect(await repo.list(), isEmpty);
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

  test('remove deletes a repo-only terminal record — a task '
      'terminal before restart is never in _tasks', () async {
    final now = DateTime.now().toUtc();
    await repo.upsert(DownloadTask(
        id: const TaskId('m-done'),
        kind: TaskKind.media,
        status: DownloadStatus.completed,
        source: DownloadSource(initialUrl: 'https://x/w'),
        output: OutputSpec(targetDirectory: dir.path),
        createdAt: now,
        updatedAt: now));
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(
          const MediaPlan(finalFileName: 'v.mp4', steps: [])),
      muxer: FakeMuxer(),
    );
    await mc.recover();
    // list() still surfaces it (media.list snapshot), so the UI
    // can render it — remove() must delete the record, not no-op.
    expect((await mc.tasks()).map((t) => t.id.value),
        contains('m-done'));
    await mc.remove(const TaskId('m-done'));
    expect(await repo.list(), isEmpty);
    await mc.dispose();
  });

  test('tasks() reports records recovered to a terminal state — '
      'the broadcast emission fired before UI attached', () async {
    // Simulate a previous host's persisted task, then recover.
    final now = DateTime.now().toUtc();
    await repo.upsert(DownloadTask(
        id: const TaskId('m-stale'),
        kind: TaskKind.media,
        status: DownloadStatus.downloadingVideo,
        source: DownloadSource(initialUrl: 'https://x/w'),
        output: OutputSpec(targetDirectory: dir.path),
        createdAt: now,
        updatedAt: now));
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(
          const MediaPlan(finalFileName: 'v.mp4', steps: [])),
      muxer: FakeMuxer(),
    );
    await mc.recover();

    final list = await mc.tasks();
    final t =
        list.singleWhere((e) => e.id.value == 'm-stale');
    expect(t.status, DownloadStatus.failed);
    expect(t.kind, TaskKind.media);
    await mc.dispose();
  });

  test('each task gets a private workDir under the shared root — '
      'same-named outputs cannot cross-pollinate', () async {
    final engine = FakeEngine();
    final mc = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4',
              role: 'video'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    final a = await mc.enqueueMedia(
        const MediaSelection(pageUrl: 'https://x/1'),
        workDir: '${dir.path}/work',
        targetDirectory: dir.path);
    final b = await mc.enqueueMedia(
        const MediaSelection(pageUrl: 'https://x/2'),
        workDir: '${dir.path}/work',
        targetDirectory: dir.path);
    await waitFor(mc, a.id, DownloadStatus.completed);
    await waitFor(mc, b.id, DownloadStatus.completed);
    final da = engine.requests[a.id.value]!.output.targetDirectory;
    final db = engine.requests[b.id.value]!.output.targetDirectory;
    expect(da, isNot(db));
    expect(da, endsWith(a.id.value));
    expect(db, endsWith(b.id.value));
    await mc.dispose();
  });

  test('unwritable workDir fails the task instead of stranding it '
      'in created', () async {
    final blocker = File('${dir.path}${Platform.pathSeparator}file')
      ..writeAsBytesSync([0]);
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
      repository: repo,
      eventBus: bus,
      resolver: FakeResolver(const MediaPlan(
        finalFileName: 'v.mp4',
        steps: [
          EngineDownloadStep(
              url: 'http://x/v', outputFileName: 'v.mp4',
              role: 'video'),
        ],
      )),
      muxer: FakeMuxer(),
    );
    final t = await mc.enqueueMedia(
        const MediaSelection(pageUrl: 'https://x/1'),
        workDir: blocker.path, // a file — dir create must throw
        targetDirectory: dir.path);
    final done = await waitFor(mc, t.id, DownloadStatus.failed);
    expect(done.status, DownloadStatus.failed);
    await mc.dispose();
  });

  test('same finalFileName twice delivers to unique names — never '
      'overwrites', () async {
    // Two tasks producing the same output name must collide-rename
    // (name (1).ext): a copy fallback that overwrote the existing
    // file would silently destroy the first download.
    final dl = FakeDownloader();
    final mc = MediaDownloadCoordinator(
      engine: FakeEngine(),
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
    const sel = MediaSelection(pageUrl: 'https://x/watch');
    final t1 = await mc.enqueueMedia(sel,
        workDir: '${dir.path}/work', targetDirectory: dir.path);
    final t2 = await mc.enqueueMedia(sel,
        workDir: '${dir.path}/work', targetDirectory: dir.path);
    await waitFor(mc, t1.id, DownloadStatus.completed);
    await waitFor(mc, t2.id, DownloadStatus.completed);
    expect(File('${dir.path}/v.mp4').existsSync(), isTrue);
    expect(File('${dir.path}/v (1).mp4').existsSync(), isTrue,
        reason: 'second delivery overwrote the first file');
    await mc.dispose();
  });
}
