import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:test/test.dart';

/// Deterministic in-memory engine — tests drive its event channels.
final class FakeEngine implements DownloadEngine {
  final controllers = <String, StreamController<EngineEvent>>{};
  final started = <String>[];
  final created = <String>[];
  final paused = <String>[];
  final cancelled = <String>[];
  final speedLimits = <String, int?>{};
  bool supportsSpeedLimit;
  bool autoComplete;

  FakeEngine({this.supportsSpeedLimit = false, this.autoComplete = false});

  @override
  String get providerId => 'engine.fake';
  @override
  int get apiVersion => 1;
  @override
  Future<EngineCapabilities> capabilities() async => EngineCapabilities(
      segmentedDownload: true,
      dynamicConnections: false,
      resume: true,
      customHeaders: true,
      cookies: true,
      referer: true,
      proxy: false,
      speedLimit: supportsSpeedLimit,
      http2: false,
      ftp: false,
      torrent: false);

  @override
  Future<ProbeResult> probe(DownloadRequest request) async =>
      ProbeResult(
          supported: true,
          fileName: 'file.bin',
          totalBytes: 1000,
          acceptsRanges: true,
          finalUrl: request.source.effectiveUrl);

  /// Number of create() calls that should throw before succeeding —
  /// models a transient engine/isolate spawn failure.
  int createFailures = 0;

  @override
  Future<EngineTaskHandle> create(TaskId id, DownloadRequest request) async {
    if (createFailures > 0) {
      createFailures--;
      throw StateError('engine spawn failed');
    }
    created.add(id.value);
    controllers[id.value] = StreamController<EngineEvent>();
    return EngineTaskHandle(engineTaskId: id.value);
  }

  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    if (autoComplete) {
      controllers[id.value]!.add(EngineProgress(
          receivedBytes: 1000, totalBytes: 1000));
      controllers[id.value]!.add(const EngineCompleted(outputPath: null));
    }
  }

  @override
  Future<void> pause(TaskId id) async {
    paused.add(id.value);
    controllers[id.value]?.add(const EnginePaused());
  }

  @override
  Future<void> resume(TaskId id) async => start(id);
  @override
  Future<void> cancel(TaskId id) async {
    cancelled.add(id.value);
    controllers[id.value]
        ?.add(const EngineFailed(ErrorCode.cancelledByUser));
  }

  @override
  Future<void> checkpoint(TaskId id) async {}
  @override
  Future<void> replaceSource(TaskId id, DownloadRequest r) async {}
  @override
  Future<void> setSpeedLimit(TaskId id, int? bps) async {
    speedLimits[id.value] = bps;
  }

  @override
  bool isKnown(TaskId id) => controllers.containsKey(id.value);
  @override
  Stream<EngineEvent> events(TaskId id) =>
      controllers[id.value]!.stream;

  void emit(TaskId id, EngineEvent e) => controllers[id.value]!.add(e);
}

/// start() blocks on a gate — models the isolate-spawn await in the
/// real adapter, opening the cancel-during-start window.
final class GatedStartEngine extends FakeEngine {
  final startGate = Completer<void>();
  @override
  Future<void> start(TaskId id) async {
    started.add(id.value);
    await startGate.future;
  }
}

/// Repo wrapper whose writes can be held on a gate — models a slow
/// disk so tests can observe whether flush() really drains a write
/// that is already in flight.
final class GatedRepo implements TaskRepository {
  GatedRepo(this.inner);
  final TaskRepository inner;
  var _gate = Completer<void>()..complete();

  void closeGate() => _gate = Completer<void>();
  void openGate() => _gate.complete();

  @override
  Future<void> upsert(DownloadTask task) =>
      _gate.future.then((_) => inner.upsert(task));
  @override
  Future<DownloadTask?> get(TaskId id) => inner.get(id);
  @override
  Future<List<DownloadTask>> list({String? queueId}) =>
      inner.list(queueId: queueId);
  @override
  Future<List<DownloadTask>> listActive() => inner.listActive();
  @override
  Future<void> delete(TaskId id) => inner.delete(id);
  @override
  Future<int> countByEngineBundle(String componentId, String version) =>
      inner.countByEngineBundle(componentId, version);
}

void main() {
  late Directory dir;
  late JsonTaskRepository repo;
  late InMemoryEventBus bus;
  var seq = 0;
  TaskId nextId() => TaskId('t${seq++}');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('freedm-app');
    repo = await JsonTaskRepository.open(dir);
    bus = InMemoryEventBus();
    seq = 0;
  });
  tearDown(() async {
    await bus.close();
    await repo.pending; // drain queued writes before deleting the dir
    // Windows: async pipeline writes can land just after the drain —
    // retry briefly instead of racing the filesystem.
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

  DownloadRequest req([String url = 'http://x/f.bin']) =>
      DownloadRequest(
        source: DownloadSource(initialUrl: url),
        output: OutputSpec(targetDirectory: dir.path),
      );

  DownloadScheduler sched(FakeEngine e, {int maxConcurrent = 3}) =>
      DownloadScheduler(
        engine: e,
        repository: repo,
        eventBus: bus,
        idGenerator: nextId,
        maxConcurrent: maxConcurrent,
      );

  /// Waits until [pred] holds on the task, watching scheduler changes.
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

  test('autoStart:false parks the task; start() admits it', () async {
    final e = FakeEngine(autoComplete: true);
    final s = sched(e);
    final t = await s.enqueue(req(), autoStart: false);
    // Held: no probe, no engine call — but persisted to the repo.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.task(t.id)!.status, DownloadStatus.created);
    expect(e.created, isEmpty);
    await s.start(t.id);
    final done = await until(s, t.id,
        (x) => x.status == DownloadStatus.completed);
    expect(done.status, DownloadStatus.completed);
    expect(e.started, contains(t.id.value));
    await s.dispose();
  });

  test('concurrency cap: only N dispatched at once', () async {
    final e = FakeEngine();
    final s = sched(e, maxConcurrent: 2);
    final ids = <TaskId>[];
    for (var i = 0; i < 4; i++) {
      ids.add((await s.enqueue(req('http://x/$i'))).id);
    }
    await until(s, ids[0], (t) => t.status == DownloadStatus.downloading);
    await until(s, ids[3], (t) => t.status == DownloadStatus.ready);
    expect(e.started.length, 2);
    await s.dispose();
  });

  test('priority: higher priority wins the freed slot', () async {
    final e = FakeEngine();
    final s = sched(e, maxConcurrent: 1);
    final a = await s.enqueue(req('http://x/a'), priority: 0);
    await until(s, a.id, (t) => t.status == DownloadStatus.downloading);
    final low = await s.enqueue(req('http://x/low'), priority: 1);
    final high = await s.enqueue(req('http://x/high'), priority: 9);
    await until(s, high.id, (t) => t.status == DownloadStatus.ready);
    await until(s, low.id, (t) => t.status == DownloadStatus.ready);

    e.emit(a.id, const EngineCompleted(outputPath: null));
    await until(
        s, high.id, (t) => t.status == DownloadStatus.downloading);
    expect(e.started.last, high.id.value);
    expect(s.task(low.id)!.status, DownloadStatus.ready);
    await s.dispose();
  });

  test('pause/resume/cancel drive state machine + engine', () async {
    final e = FakeEngine();
    final s = sched(e);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    await s.pause(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.paused);
    expect(e.paused, [t.id.value]);

    await s.resume(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    await s.cancel(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.cancelled);
    expect(e.cancelled, contains(t.id.value));
    await s.dispose();
  });

  test('cancel during engine start stops the just-started task',
      () async {
    final e = GatedStartEngine();
    final s = sched(e);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);
    for (var i = 0; i < 100 && e.started.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e.started, contains(t.id.value));

    // Cancel while engine.start is still in flight → terminal…
    await s.cancel(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.cancelled);

    // …then release the start — the post-start guard must cancel the
    // just-started engine task instead of leaving an untracked
    // download running (zombie).
    e.startGate.complete();
    for (var i = 0; i < 100 && e.cancelled.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e.cancelled.where((id) => id == t.id.value).length, 2,
        reason: 'user cancel + post-start guard cancel expected');
    await s.dispose();
  });

  test('retryable engine failure schedules retry then succeeds',
      () async {
    final e = FakeEngine();
    final s = sched(e);
    final t = await s.enqueue(req(),
        retryPolicy: const RetryPolicy(
            maxAttempts: 2, initialDelay: Duration(milliseconds: 30)));
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    e.emit(t.id, const EngineFailed(ErrorCode.connectionDropped));
    await until(s, t.id, (x) => x.status == DownloadStatus.retryWait);
    final retried =
        await until(s, t.id, (x) => x.status == DownloadStatus.downloading);
    expect(retried.failedAttempts, 1);
    expect(e.started.length, greaterThanOrEqualTo(2));
    await s.dispose();
  });

  test('non-retryable failure goes straight to failed', () async {
    final e = FakeEngine();
    final s = sched(e);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);
    e.emit(t.id, const EngineFailed(ErrorCode.notFound));
    await until(s, t.id, (x) => x.status == DownloadStatus.failed);
    await s.dispose();
  });

  test('checksum is verified on completion', () async {
    final f = File('${dir.path}\\payload.bin')
      ..writeAsBytesSync(List.filled(64, 3));
    final good =
        'sha256:${sha256.convert(List.filled(64, 3))}';
    final e = FakeEngine();
    final s = sched(e);

    final ok = await s.enqueue(DownloadRequest(
      source: const DownloadSource(initialUrl: 'http://x/ok'),
      output: OutputSpec(targetDirectory: dir.path, checksum: good),
    ));
    await until(s, ok.id, (x) => x.status == DownloadStatus.downloading);
    e.emit(ok.id, EngineCompleted(outputPath: f.path));
    await until(s, ok.id, (x) => x.status == DownloadStatus.completed);

    final bad = await s.enqueue(DownloadRequest(
      source: const DownloadSource(initialUrl: 'http://x/bad'),
      output: OutputSpec(
          targetDirectory: dir.path, checksum: 'sha256:${'0' * 64}'),
    ));
    await until(s, bad.id, (x) => x.status == DownloadStatus.downloading);
    e.emit(bad.id, EngineCompleted(outputPath: f.path));
    final failed = await until(
        s, bad.id, (x) => x.status == DownloadStatus.failed);
    expect(failed.lastError, ErrorCode.checksumMismatch);
    await s.dispose();
  });

  test('speed limit is plumbed only when the engine supports it',
      () async {
    final noCap = FakeEngine(supportsSpeedLimit: false);
    final s1 = sched(noCap);
    final t1 = await s1.enqueue(req());
    await until(s1, t1.id, (x) => x.status == DownloadStatus.downloading);
    await s1.setTaskSpeedLimit(t1.id, 1234);
    expect(noCap.speedLimits, isEmpty);
    expect(await s1.engineSupportsSpeedLimit, isFalse);
    await s1.dispose();

    final cap = FakeEngine(supportsSpeedLimit: true);
    final s2 = sched(cap);
    final t2 = await s2.enqueue(req());
    await until(s2, t2.id, (x) => x.status == DownloadStatus.downloading);
    await s2.setTaskSpeedLimit(t2.id, 1234);
    expect(cap.speedLimits[t2.id.value], 1234);
    await s2.dispose();
  });

  test('restart recovery: paused stays, downloading re-attaches',
      () async {
    final e1 = FakeEngine();
    final s1 = sched(e1);
    final running = await s1.enqueue(req('http://x/run'));
    await until(
        s1, running.id, (x) => x.status == DownloadStatus.downloading);
    final idle = await s1.enqueue(req('http://x/pause-me'));
    // wait for it to be dispatched then pause
    await until(s1, idle.id, (x) => x.status == DownloadStatus.downloading);
    await s1.pause(idle.id);
    await until(s1, idle.id, (x) => x.status == DownloadStatus.paused);
    await s1.dispose(); // simulate process exit (repo keeps state)

    final e2 = FakeEngine();
    final s2 = sched(e2);
    await s2.recover();

    expect(s2.task(idle.id)!.status, DownloadStatus.paused);
    // The previously-downloading task is re-created and restarted.
    await until(
        s2, running.id, (x) => x.status == DownloadStatus.downloading);
    expect(e2.created, contains(running.id.value));
    expect(e2.started, contains(running.id.value));
    // Paused task is NOT started until user resumes.
    expect(e2.started, isNot(contains(idle.id.value)));
    await s2.dispose();
  });

  test('engine create failure retries instead of dying instantly',
      () async {
    final e = FakeEngine()..createFailures = 1;
    final s = sched(e);
    final t = await s.enqueue(req(),
        retryPolicy: const RetryPolicy(
            maxAttempts: 2, initialDelay: Duration(milliseconds: 30)));
    // create() threw → retryable engineUnavailable → retryWait,
    // then the re-armed timer re-dispatches and the second
    // create+start succeeds.
    await until(s, t.id, (x) => x.status == DownloadStatus.retryWait);
    final back = await until(
        s, t.id, (x) => x.status == DownloadStatus.downloading);
    expect(back.failedAttempts, 1);
    expect(e.created, [t.id.value]);
    expect(e.started, [t.id.value]);
    await s.dispose();
  });

  test('cancel during a failing engine start stays cancelled',
      () async {
    final e = GatedStartEngine();
    final s = sched(e);
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);
    for (var i = 0; i < 100 && e.started.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await s.cancel(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.cancelled);
    // Engine start then fails — the dispatch-failure path must not
    // resurrect the terminal task (cancelled→failed would throw an
    // InvalidTransitionError inside the scheduler's async void).
    e.startGate.completeError(StateError('spawn died'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.task(t.id)!.status, DownloadStatus.cancelled);
    await s.dispose();
  });

  test('restart recovery: retryWait re-arms its backoff timer',
      () async {
    final e1 = FakeEngine();
    final s1 = sched(e1);
    final t = await s1.enqueue(req(),
        retryPolicy: const RetryPolicy(
            maxAttempts: 3, initialDelay: Duration(milliseconds: 30)));
    await until(s1, t.id, (x) => x.status == DownloadStatus.downloading);
    e1.emit(t.id, const EngineFailed(ErrorCode.connectionDropped));
    await until(s1, t.id, (x) => x.status == DownloadStatus.retryWait);
    await repo.pending; // the retryWait record must be durable
    await s1.dispose(); // dies with the timer still pending

    final e2 = FakeEngine();
    final s2 = sched(e2);
    await s2.recover();
    // The re-armed timer fires → reattach → downloading again.
    final back = await until(
        s2, t.id, (x) => x.status == DownloadStatus.downloading);
    expect(back.failedAttempts, 1);
    // Status flips before engine.create lands — poll for it.
    for (var i = 0; i < 50 && !e2.created.contains(t.id.value); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e2.created, contains(t.id.value));
    expect(e2.started, contains(t.id.value));
    await s2.dispose();
  });

  test('pause during retryWait disarms the backoff timer', () async {
    final e = FakeEngine();
    final s = sched(e);
    final t = await s.enqueue(req(),
        retryPolicy: const RetryPolicy(
            maxAttempts: 3, initialDelay: Duration(milliseconds: 60)));
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);
    e.emit(t.id, const EngineFailed(ErrorCode.connectionDropped));
    await until(s, t.id, (x) => x.status == DownloadStatus.retryWait);

    await s.pause(t.id);
    await until(s, t.id, (x) => x.status == DownloadStatus.paused);
    // Well past the 60ms backoff — the timer must not fire under
    // the pause and re-dispatch the task.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(s.task(t.id)!.status, DownloadStatus.paused);
    expect(e.started.where((id) => id == t.id.value).length, 1);
    await s.dispose();
  });

  test('pause on a queued ready task blocks dispatch', () async {
    final e = FakeEngine();
    final s = sched(e, maxConcurrent: 1);
    final a = await s.enqueue(req('http://x/a'));
    final b = await s.enqueue(req('http://x/b'));
    await until(s, a.id, (x) => x.status == DownloadStatus.downloading);
    await until(s, b.id, (x) => x.status == DownloadStatus.ready);

    await s.pause(b.id);
    expect(s.task(b.id)!.status, DownloadStatus.paused);

    // Free the slot — the paused task must not be dispatched.
    e.emit(a.id, const EngineCompleted(outputPath: null));
    await until(s, a.id, (x) => x.status == DownloadStatus.completed);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(e.started, isNot(contains(b.id.value)));
    expect(s.task(b.id)!.status, DownloadStatus.paused);

    // Resume admits it through the normal path.
    await s.resume(b.id);
    await until(s, b.id, (x) => x.status == DownloadStatus.downloading);
    expect(e.started, contains(b.id.value));
    await s.dispose();
  });

  test('pause acknowledgement frees the slot for queued work',
      () async {
    final e = FakeEngine();
    final s = sched(e, maxConcurrent: 1);
    final a = await s.enqueue(req('http://x/a'));
    final b = await s.enqueue(req('http://x/b'));
    await until(s, a.id, (x) => x.status == DownloadStatus.downloading);
    await until(s, b.id, (x) => x.status == DownloadStatus.ready);

    // Pause lands → EnginePaused → paused frees the slot → b pumps
    // without waiting for another unrelated event.
    await s.pause(a.id);
    await until(s, b.id, (x) => x.status == DownloadStatus.downloading);
    expect(e.started, contains(b.id.value));
    await s.dispose();
  });

  test('flush drains a debounce write that already fired', () async {
    final gated = GatedRepo(repo);
    final e = FakeEngine();
    final s = DownloadScheduler(
      engine: e,
      repository: gated,
      eventBus: bus,
      idGenerator: nextId,
    );
    final t = await s.enqueue(req());
    await until(s, t.id, (x) => x.status == DownloadStatus.downloading);

    // Close the gate, emit progress, let the debounce timer fire —
    // its upsert is now in flight but not reachable via the
    // _persistDebounce map (the timer already removed its key).
    gated.closeGate();
    e.emit(t.id,
        const EngineProgress(receivedBytes: 500, totalBytes: 1000));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    var flushed = false;
    final f = s.flush().then((_) => flushed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(flushed, isFalse,
        reason: 'flush must await the in-flight debounced write');
    gated.openGate();
    await f;
    expect(flushed, isTrue);
    expect((await repo.get(t.id))!.receivedBytes, 500);
    await s.dispose();
  });

  test('remove deletes a repo-only terminal record after restart',
      () async {
    final e1 = FakeEngine(autoComplete: true);
    final s1 = sched(e1);
    final t = await s1.enqueue(req());
    await until(
        s1, t.id, (x) => x.status == DownloadStatus.completed);
    await s1.dispose(); // repo keeps the terminal record

    // Fresh scheduler: recover() loads only active tasks, so the
    // completed record isn't in _tasks — remove() must still delete
    // it instead of dying on cancel's 'unknown task'.
    final s2 = sched(FakeEngine());
    await s2.recover();
    expect((await s2.tasks()).map((x) => x.id.value),
        contains(t.id.value));
    await s2.remove(t.id);
    expect(await s2.tasks(), isEmpty);
    await s2.dispose();
  });
}
