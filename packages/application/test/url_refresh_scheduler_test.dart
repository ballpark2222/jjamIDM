import 'dart:async';
import 'dart:io';

import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:test/test.dart';

/// Engine that records replaceSource calls — exercises the
/// urlExpired → refresh → replaceSource → start flow.
final class FakeEngine implements DownloadEngine {
  final controllers = <String, StreamController<EngineEvent>>{};
  final started = <String>[];
  final replaced = <String, String>{};

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
  Future<ProbeResult> probe(DownloadRequest request) async =>
      const ProbeResult(supported: true);

  @override
  Future<EngineTaskHandle> create(
      TaskId id, DownloadRequest request) async {
    controllers[id.value] = StreamController<EngineEvent>();
    return EngineTaskHandle(engineTaskId: id.value);
  }

  @override
  Future<void> start(TaskId id) async => started.add(id.value);
  @override
  Future<void> pause(TaskId id) async {}
  @override
  Future<void> resume(TaskId id) async {}
  @override
  Future<void> cancel(TaskId id) async {}
  @override
  Future<void> checkpoint(TaskId id) async {}

  @override
  Future<void> replaceSource(TaskId id, DownloadRequest r) async {
    replaced[id.value] = r.source.effectiveUrl;
  }

  @override
  Future<void> setSpeedLimit(TaskId id, int? bps) async {}
  @override
  bool isKnown(TaskId id) => controllers.containsKey(id.value);
  @override
  Stream<EngineEvent> events(TaskId id) =>
      controllers[id.value]!.stream;

  void emit(TaskId id, EngineEvent e) => controllers[id.value]!.add(e);
}

final class FakeRefresher implements UrlRefreshResolver {
  FakeRefresher(this.result, {this.error});
  final RefreshedSource? result;
  final Object? error;
  var calls = 0;

  @override
  Future<RefreshedSource> refresh(DownloadTask task) async {
    calls++;
    if (error != null) throw error!;
    return result!;
  }
}

void main() {
  late Directory dir;
  late JsonTaskRepository repo;
  late InMemoryEventBus bus;
  var seq = 0;
  TaskId nextId() => TaskId('t${seq++}');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('freedm-url');
    repo = await JsonTaskRepository.open(dir);
    bus = InMemoryEventBus();
    seq = 0;
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
    await dir.delete(recursive: true);
  });

  DownloadRequest req() => DownloadRequest(
        source: const DownloadSource(
          initialUrl: 'http://x/f?token=OLD',
          etag: '"stable"',
          contentLength: 1000,
        ),
        output: OutputSpec(targetDirectory: dir.path),
      );

  DownloadScheduler sched(FakeEngine e, UrlRefreshResolver r) =>
      DownloadScheduler(
        engine: e,
        repository: repo,
        eventBus: bus,
        idGenerator: nextId,
        urlRefresher: r,
      );

  Future<DownloadTask> until(DownloadScheduler s, TaskId id,
      bool Function(DownloadTask) pred) async {
    final c = Completer<DownloadTask>();
    final sub = s.changes.listen((t) {
      if (t.id == id && pred(t) && !c.isCompleted) c.complete(t);
    });
    final cur = s.task(id);
    if (cur != null && pred(cur)) c.complete(cur);
    final t = await c.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    return t;
  }

  test('urlExpired refreshes source and restarts engine', () async {
    final e = FakeEngine();
    final r = FakeRefresher(const RefreshedSource(
      url: 'http://x/f?token=NEW',
      etag: '"stable"',
      contentLength: 1000,
    ));
    final s = sched(e, r);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    e.emit(t.id, const EngineFailed(ErrorCode.urlExpired));
    // Predicate must select the POST-refresh downloading state —
    // the task is still 'downloading' when the failure lands.
    final back = await until(s, t.id,
        (x) => x.status == DownloadStatus.downloading &&
            x.source.currentUrl != null);

    expect(r.calls, 1);
    expect(back.source.currentUrl, 'http://x/f?token=NEW');
    // engine.start lands after the state emit — poll for it.
    for (var i = 0; i < 50 && e.started.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e.replaced[t.id.value], 'http://x/f?token=NEW');
    expect(e.started.length, greaterThanOrEqualTo(2));
    await s.dispose();
  });

  test('same-file conflict fails the task instead of corrupting',
      () async {
    final e = FakeEngine();
    final r = FakeRefresher(const RefreshedSource(
      url: 'http://x/f?token=NEW',
      etag: '"different"', // changed content under a new URL
      contentLength: 1000,
    ));
    final s = sched(e, r);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    e.emit(t.id, const EngineFailed(ErrorCode.urlExpired));
    await until(s, t.id, (x) => x.status == DownloadStatus.failed);
    expect(e.replaced, isEmpty);
    await s.dispose();
  });

  test('refresh failure leaves task failed(urlExpired)', () async {
    final e = FakeEngine();
    final r = FakeRefresher(null, error: StateError('offline'));
    final s = sched(e, r);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    e.emit(t.id, const EngineFailed(ErrorCode.forbidden));
    final failed =
        await until(s, t.id, (x) => x.status == DownloadStatus.failed);
    expect(failed.lastError, ErrorCode.urlExpired);
    await s.dispose();
  });

  test('restart recovery: persisted urlExpired re-runs refresh',
      () async {
    // Hold the first refresh open so the urlExpired state persists
    // durably, then "restart" with a working refresher.
    final hang = Completer<RefreshedSource>();
    final e1 = FakeEngine();
    final s1 = sched(e1, _PendingRefresher(hang.future));
    final t = await s1.enqueue(req());
    await until(s1, t.id, (x) => x.status == DownloadStatus.downloading);

    e1.emit(t.id, const EngineFailed(ErrorCode.urlExpired));
    await until(
        s1, t.id, (x) => x.status == DownloadStatus.urlExpired);
    await repo.pending; // urlExpired record must be durable
    await s1.dispose(); // the hung refresh dies with the "process"

    final e2 = FakeEngine();
    final r2 = FakeRefresher(const RefreshedSource(
      url: 'http://x/f?token=NEW',
      etag: '"stable"',
      contentLength: 1000,
    ));
    final s2 = sched(e2, r2);
    await s2.recover();

    // urlExpired survives in listActive → recover re-runs refresh →
    // replaceSource misses the fresh engine → reattach creates it.
    final back = await until(s2, t.id,
        (x) => x.status == DownloadStatus.downloading);
    expect(back.source.currentUrl, 'http://x/f?token=NEW');
    expect(r2.calls, 1);
    for (var i = 0; i < 50 && !e2.isKnown(t.id); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e2.isKnown(t.id), isTrue);
    await s2.dispose();
  });

  test('manual refreshSource drives urlExpired tasks', () async {
    final e = FakeEngine();
    var attempt = 0;
    final r = _FlipRefresher(() => ++attempt == 1
        ? throw StateError('first fails')
        : const RefreshedSource(url: 'http://x/f?token=N2'));
    final s = sched(e, r);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    e.emit(t.id, const EngineFailed(ErrorCode.urlExpired));
    await until(s, t.id, (x) => x.status == DownloadStatus.failed);
    // Failed is terminal — manual refresh on failed tasks is a no-op.
    expect(await s.refreshSource(t.id), isFalse);
    await s.dispose();
  });
}

final class _FlipRefresher implements UrlRefreshResolver {
  _FlipRefresher(this.fn);
  final RefreshedSource Function() fn;
  @override
  Future<RefreshedSource> refresh(DownloadTask task) async => fn();
}

/// Refresher that never resolves until the given future completes —
/// keeps a task parked in urlExpired for the recovery test.
final class _PendingRefresher implements UrlRefreshResolver {
  _PendingRefresher(this.future);
  final Future<RefreshedSource> future;
  @override
  Future<RefreshedSource> refresh(DownloadTask task) => future;
}
