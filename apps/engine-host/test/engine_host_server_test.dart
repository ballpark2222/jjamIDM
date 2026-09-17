import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_host/engine_host_server.dart';
import 'package:freedm_engine_protocol/freedm_engine_protocol.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:test/test.dart';

/// In-process EngineHostServer tests — the wire side of queue-mode
/// subscribe semantics and media.list that the RPC client cannot
/// observe (its events() swallows subscribe errors deliberately).

final class _FakeEngine implements DownloadEngine {
  final controllers = <String, StreamController<EngineEvent>>{};

  @override
  String get providerId => 'engine.fake';
  @override
  int get apiVersion => 2;
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
    controllers[id.value] =
        StreamController<EngineEvent>.broadcast();
    return EngineTaskHandle(engineTaskId: id.value);
  }

  @override
  Future<void> start(TaskId id) async {}
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
  Stream<EngineEvent> events(TaskId id) =>
      controllers[id.value]?.stream ?? const Stream.empty();
}

final class _FakeResolver implements MediaResolver {
  @override
  String get providerId => 'media.fake';
  @override
  int get apiVersion => 1;
  @override
  Future<MediaProbe> probe(String url,
          {Map<String, String> headers = const {},
          String? cookieRef}) async =>
      const MediaProbe(supported: true, title: 't');
  @override
  Future<MediaPlan> plan(MediaSelection s,
          {Map<String, String> headers = const {}}) async =>
      const MediaPlan(steps: [], finalFileName: 'out');
  @override
  Future<String> version() async => 'fake';
}

final class _FakeMuxer implements MediaMuxer {
  @override
  String get providerId => 'media.ffmpeg-fake';
  @override
  Future<MuxResult> mux(MuxStep step, {String? workDir}) async =>
      const MuxResult(ok: false, error: 'not exercised');
  @override
  Future<MuxResult> attachSubtitles(String v, List<String> subs,
          {String? outputPath}) async =>
      MuxResult(ok: true, outputPath: outputPath ?? v);
  @override
  Future<String> version() async => 'fake';
}

/// Drives a server over a String line stream and captures its
/// NDJSON output through a file-backed sink (IOSink needs a real
/// flush target — StringBuffer-based IOSinks buffer internally).
final class _Rig {
  _Rig._(this.lines, this.out, this.outFile);

  final StreamController<String> lines;
  final IOSink out;
  final File outFile;

  void send(String method,
      [Map<String, Object?> params = const {}, int id = 1]) {
    lines.add(
        RpcRequest(id: id, method: method, params: params).encode());
  }

  /// All frames written so far, decoded.
  Future<List<Map<String, Object?>>> frames() async {
    await out.flush();
    return [
      for (final l in const LineSplitter()
          .convert(await outFile.readAsString()))
        (jsonDecode(l) as Map).cast<String, Object?>()
    ];
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ehs');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows file locks can lag a beat.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tmp.delete(recursive: true);
    }
  });

  Future<({EngineHostServer server, _Rig rig, Future<void> done})>
      wire({DownloadScheduler? scheduler,
          MediaDownloadCoordinator? media}) async {
    final outFile = File('${tmp.path}${Platform.pathSeparator}'
        'out-${DateTime.now().microsecondsSinceEpoch}.ndjson');
    final out = outFile.openWrite();
    final server = EngineHostServer(
        engine: _FakeEngine(),
        tempRoot: tmp,
        media: media,
        scheduler: scheduler,
        out: out);
    final lines = StreamController<String>();
    final rig = _Rig._(lines, out, outFile);
    final done = server.run(lines.stream);
    return (server: server, rig: rig, done: done);
  }

  Future<void> closeRig(_Rig rig, Future<void> done) async {
    await rig.lines.close();
    await done;
    await rig.out.close();
  }

  Future<DownloadScheduler> scheduler() async {
    final repo = await JsonTaskRepository.open(
        Directory('${tmp.path}${Platform.pathSeparator}queue'));
    var seq = 0;
    return DownloadScheduler(
        engine: _FakeEngine(),
        repository: repo,
        eventBus: InMemoryEventBus(),
        idGenerator: () => TaskId('gen-${seq++}'));
  }

  test('queue mode: subscribeEvents for an unknown task errors '
      '(no dead listener)', () async {
    final s = await scheduler();
    final w = await wire(scheduler: s);
    w.rig.send(EngineProtocol.taskSubscribeEvents,
        {'taskId': 'ghost'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final frames = await w.rig.frames();
    final res = frames.singleWhere((f) => f['id'] == 1);
    expect(res['error'], isNotNull);
    expect(
        (res['error'] as Map)['code'], RpcError.taskNotFound);
    await closeRig(w.rig, w.done);
    await s.dispose();
  });

  test('queue mode: subscribeEvents for a parked task answers ok '
      'and pushes a status snapshot', () async {
    final s = await scheduler();
    await s.enqueue(
        DownloadRequest(
            source: DownloadSource(initialUrl: 'http://x/f'),
            output: OutputSpec(targetDirectory: tmp.path)),
        id: const TaskId('parked-1'),
        autoStart: false);
    final w = await wire(scheduler: s);
    w.rig.send(EngineProtocol.taskSubscribeEvents,
        {'taskId': 'parked-1'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final frames = await w.rig.frames();
    final res = frames.singleWhere((f) => f['id'] == 1);
    expect(res['error'], isNull);
    expect(
        frames.any((f) =>
            f['method'] == EngineProtocol.taskEvent &&
            (f['params'] as Map)['status'] == 'created'),
        isTrue);
    await closeRig(w.rig, w.done);
    await s.dispose();
  });

  test('media.list without a media pipeline → unsupported', () async {
    final w = await wire();
    w.rig.send(EngineProtocol.mediaList);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final frames = await w.rig.frames();
    final res = frames.singleWhere((f) => f['id'] == 1);
    expect((res['error'] as Map)['code'], RpcError.unsupported);
    await closeRig(w.rig, w.done);
  });

  test('media.list returns tasks recovered before the client '
      'attached — the event broadcast already fired', () async {
    // Seed the media repo with a task that was mid-flight when the
    // previous host died, then recover it on this "host".
    final repo = await JsonTaskRepository.open(
        Directory('${tmp.path}${Platform.pathSeparator}media'));
    final now = DateTime.now().toUtc();
    await repo.upsert(DownloadTask(
        id: const TaskId('m-restored'),
        kind: TaskKind.media,
        status: DownloadStatus.downloadingVideo,
        source: DownloadSource(initialUrl: 'https://v.example/p'),
        output: OutputSpec(targetDirectory: tmp.path),
        createdAt: now,
        updatedAt: now));
    final media = MediaDownloadCoordinator(
        engine: _FakeEngine(),
        repository: repo,
        eventBus: InMemoryEventBus(),
        resolver: _FakeResolver(),
        muxer: _FakeMuxer(),
        componentDownloaders: const {});

    // Server constructed before recover() — the subscription is
    // live, so the failed transition lands on the wire too.
    final w = await wire(media: media);
    await media.recover();

    w.rig.send(EngineProtocol.mediaList);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final frames = await w.rig.frames();

    // Recovery emission reached the wire as a media.event.
    final ev = frames.where((f) =>
        f['method'] == EngineProtocol.mediaEvent &&
        ((f['params'] as Map)['task'] as Map)['id'] ==
            'm-restored');
    expect(ev, isNotEmpty);
    expect((ev.last['params'] as Map)['task']
        ['status'], 'failed');

    final res = frames.singleWhere((f) => f['id'] == 1);
    final tasks =
        (res['result'] as Map)['tasks'] as List;
    final t = tasks
        .map((e) => (e as Map)['id'])
        .toList();
    expect(t, contains('m-restored'));
    await closeRig(w.rig, w.done);
    await media.dispose();
  });
}
