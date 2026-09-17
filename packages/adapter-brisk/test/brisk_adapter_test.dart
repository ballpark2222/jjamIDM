import 'dart:async';
import 'dart:io';

import 'package:brisk_engine/brisk_engine.dart' as brisk;
import 'package:crypto/crypto.dart';
import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_test_server/src/fixture_server.dart';
import 'package:test/test.dart';

void main() {
  late FixtureServer srv;
  late Directory tempRoot;
  late Directory outDir;

  // Short retry delay so drop/retry tests stay fast.
  BriskEngineAdapter newEngine() => BriskEngineAdapter(
      tempRoot: tempRoot, connectionRetryTimeoutMillis: 800);

  setUp(() async {
    srv = await FixtureServer.start();
    tempRoot = await Directory.systemTemp.createTemp('freedm-tmp');
    outDir = await Directory.systemTemp.createTemp('freedm-out');
  });
  tearDown(() async {
    await srv.close();
    await tempRoot.delete(recursive: true);
    await outDir.delete(recursive: true);
  });

  DownloadRequest req(String path,
          {Map<String, String> headers = const {},
          String? referer,
          int? conns}) =>
      DownloadRequest(
        source:
            DownloadSource(initialUrl: '${srv.base}$path', referer: referer),
        output: OutputSpec(targetDirectory: outDir.path),
        headers: headers,
        maxConnections: conns,
      );

  Future<String> expectedHash(int length) async =>
      sha256.convert(FixtureServer.fixtureBytes(length)).toString();

  test('probe reports size and range support', () async {
    final engine = newEngine();
    final p = await engine.probe(req('/file-range'));
    expect(p.supported, isTrue);
    expect(p.acceptsRanges, isTrue);
    expect(p.totalBytes, FixtureServer.defaultLength);
  });

  test('probe falls back to range GET when HEAD is rejected', () async {
    // /file-head-rejected returns 404 to HEAD but 206 to GET —
    // models CDNs that refuse HEAD (e.g. xhscdn signed URLs).
    final engine = newEngine();
    final p = await engine.probe(req('/file-head-rejected'));
    expect(p.supported, isTrue,
        reason: 'GET/Range-capable server must probe OK despite HEAD 404');
    expect(p.acceptsRanges, isTrue);
    expect(p.totalBytes, FixtureServer.defaultLength);
  });

  test('download completes on a HEAD-rejecting server', () async {
    final engine = newEngine();
    const id = TaskId('dl-nohead');
    await engine.create(id, req('/file-head-rejected', conns: 4));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineCompleted>(),
        reason: (e is EngineFailed) ? '${e.detail}' : '');

    final file = File((e as EngineCompleted).outputPath!);
    expect(sha256.convert(await file.readAsBytes()).toString(),
        await expectedHash(FixtureServer.defaultLength));
  });

  test('extensionless CDN name gains an extension from content-type',
      () async {
    // /file-video-noext: HEAD→404, URL has no extension,
    // Content-Type: video/mp4 → probe name must end in .mp4 so the
    // saved file opens on double-click.
    final engine = newEngine();
    final p = await engine.probe(req('/file-video-noext'));
    expect(p.supported, isTrue);
    expect(p.fileName, endsWith('.mp4'));
  });

  test('capabilities', () async {
    final c = await newEngine().capabilities();
    expect(c.segmentedDownload, isTrue);
    expect(c.resume, isTrue);
    expect(c.speedLimit, isFalse); // documented provider limitation
  });

  test('full download completes with matching hash', () async {
    final engine = newEngine();
    const id = TaskId('dl-basic');
    await engine.create(id, req('/file-range', conns: 8));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineCompleted>());

    final file = File((e as EngineCompleted).outputPath!);
    expect(await file.length(), FixtureServer.defaultLength);
    expect(sha256.convert(await file.readAsBytes()).toString(),
        await expectedHash(FixtureServer.defaultLength));
  });

  test('pause then resume still completes',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    final engine = newEngine();
    const id = TaskId('dl-pause');
    // Slow 4 MiB file → guaranteed mid-flight window for the pause to
    // land after connections are established (upstream quirk: a pause
    // arriving before channels exist is treated as a start).
    await engine.create(id, req('/file-slow?length=4194304&delay=40'));
    final done = Completer<EngineEvent>();
    var sawPaused = false;
    engine.events(id).listen((e) async {
      if (e is EngineProgress &&
          e.receivedBytes > 64 * 1024 &&
          !sawPaused) {
        sawPaused = true;
        await engine.pause(id);
      }
      if (e is EnginePaused) {
        await engine.resume(id);
      }
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 3));
    expect(sawPaused, isTrue);
    expect(e, isA<EngineCompleted>(),
        reason: (e is EngineFailed) ? '${e.detail}' : '');
  });

  test('cookie-gated endpoint needs headers', () async {
    final engine = newEngine();
    const id = TaskId('dl-cookie');
    await engine.create(
        id,
        req('/file-auth-cookie',
            headers: const {'cookie': 'session=fixture'}));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineCompleted>());
  });

  test('restart resume: fresh process continues partial file',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    // Brisk keeps channel state in process-wide statics, so a true
    // restart must cross a process boundary — run the worker twice.
    final worker = 'tool/restart_worker.dart';
    final url = '${srv.base}/file-slow?length=8388608&delay=80';
    Future<ProcessResult> runWorker(String mode) => Process.run(
          Platform.resolvedExecutable,
          [worker, mode, url, tempRoot.path, outDir.path],
          workingDirectory: Directory.current.path,
        );

    var r = await runWorker('partial');
    expect(r.stdout.toString(), contains('DIED'),
        reason: '${r.stdout}\n${r.stderr}');
    // Partial bytes must actually be on disk for a resume to be real.
    expect(r.stdout.toString(), contains(RegExp(r'tempBytes=[1-9]')),
        reason: r.stdout.toString());

    r = await runWorker('finish');
    expect(r.stdout.toString(), contains('DONE'),
        reason: '${r.stdout}\n${r.stderr}');

    final out = File('${outDir.path}\\file-slow');
    expect(await out.exists(), isTrue);
    expect(sha256.convert(await out.readAsBytes()).toString(),
        sha256
            .convert(FixtureServer.fixtureBytes(8 * 1024 * 1024))
            .toString());
  });

  test('dropped connection is retried to completion',
      timeout: const Timeout(Duration(minutes: 4)), () async {
    final engine = newEngine();
    const id = TaskId('dl-drop');
    // Single connection: the contract under test is mid-body drop →
    // retry → resume from written temp bytes → completion. Brisk's
    // dynamic segment-reuse can strand ranges when several connections
    // die mid-flight (upstream limitation — see docs/audit notes).
    await engine.create(id, req('/file-drop-connection', conns: 1));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 3));
    expect(e, isA<EngineCompleted>());

    final file = File((e as EngineCompleted).outputPath!);
    expect(sha256.convert(await file.readAsBytes()).toString(),
        await expectedHash(FixtureServer.defaultLength));
  });

  test('pause issued before create applies on start',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    // The scheduler flips a task to `downloading` before
    // engine.create returns — a pause in that window must queue and
    // land once the task starts, not throw or vanish.
    final engine = newEngine();
    const id = TaskId('dl-pre-pause');
    await engine.pause(id); // before create — queues internally
    // /file-hang emits one progress chunk then stalls forever — the
    // download can never outrun the queued pause.
    await engine.create(id, req('/file-hang'));
    final paused = Completer<void>();
    engine.events(id).listen((e) {
      if (e is EnginePaused && !paused.isCompleted) paused.complete();
    });
    await engine.start(id);
    await paused.future.timeout(const Duration(minutes: 2));
    // The stalled task would hang forever — cancel to clean up.
    await engine.cancel(id);
  });

  test('cancel aborts download', () async {
    final engine = newEngine();
    const id = TaskId('dl-cancel');
    // /file-hang sends one chunk then stalls — deterministic mid-flight.
    await engine.create(id, req('/file-hang'));
    final done = Completer<EngineEvent>();
    var started = false;
    engine.events(id).listen((e) async {
      if (e is EngineProgress && !started) {
        started = true;
        await engine.cancel(id);
      }
      if (e is EngineFailed) done.complete(e);
      if (e is EngineCompleted) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineFailed>());
    expect((e as EngineFailed).error, ErrorCode.cancelledByUser);
  });

  test('stale paused reports cannot re-park a resumed task',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    // Paused reports are per-connection: with several connections a
    // straggler can be delivered after resume() — it must not surface
    // as EnginePaused (that re-parked the task at the scheduler while
    // the engine kept running).
    final engine = newEngine();
    const id = TaskId('dl-stale-pause');
    await engine.create(
        id, req('/file-slow?length=4194304&delay=40', conns: 8));
    final done = Completer<EngineEvent>();
    var pauseSent = false;
    var resumed = false;
    var stalePaused = false;
    engine.events(id).listen((e) async {
      if (e is EngineProgress &&
          e.receivedBytes > 64 * 1024 &&
          !pauseSent) {
        pauseSent = true;
        await engine.pause(id);
      }
      if (e is EnginePaused) {
        if (resumed) {
          stalePaused = true; // paused event after resume = stale
        } else {
          resumed = true;
          await engine.resume(id);
        }
      }
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 3));
    expect(stalePaused, isFalse,
        reason: 'paused event surfaced after resume');
    expect(e, isA<EngineCompleted>(),
        reason: (e is EngineFailed) ? '${e.detail}' : '');
  });

  test('cancel issued before connections register still stops the task',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    // Upstream rewrites a pre-channel cancel into a start — the
    // adapter must re-send until the engine reports the task gone,
    // or the "cancelled" download continues as a zombie.
    final engine = newEngine();
    const id = TaskId('dl-fast-cancel');
    await engine.create(
        id, req('/file-slow?length=8388608&delay=40', conns: 8));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    await engine.cancel(id); // lands in the pre-channel window
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineFailed>(),
        reason: 'cancel was dropped — download kept running');
    expect((e as EngineFailed).error, ErrorCode.cancelledByUser);
    expect(
        File('${outDir.path}${Platform.pathSeparator}file-slow')
            .existsSync(),
        isFalse,
        reason: 'cancelled task produced a completed output file');
  });

  test('upstream engine isolate and statics are reaped on completion',
      () async {
    // Upstream never cleans DownloadEngine.engineIsolates /
    // engineChannels / downloadItems — a long-lived engine-host would
    // leak one isolate + 4 timers per download. The adapter reaps
    // them on terminal status.
    final engine = newEngine();
    const id = TaskId('dl-reap');
    await engine.create(id, req('/file-range', conns: 4));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 2));
    expect(e, isA<EngineCompleted>(),
        reason: (e is EngineFailed) ? '${e.detail}' : '');
    expect(brisk.DownloadEngine.engineIsolates.containsKey(id.value),
        isFalse);
    expect(brisk.DownloadEngine.engineChannels.containsKey(id.value),
        isFalse);
    expect(brisk.DownloadEngine.downloadItems.containsKey(id.value),
        isFalse);
  });

  test('dead server fails via stall watchdog and is reaped',
      () async {
    // Upstream never emits `failed` for a dead server (exhausted
    // retries stall in `connecting` forever). The adapter's
    // pre-first-byte watchdog bounds that to the retry budget —
    // without it this test hangs instead of failing.
    final engine = BriskEngineAdapter(
        tempRoot: tempRoot,
        connectionRetryTimeoutMillis: 300,
        maxConnectionRetryCount: 1);
    const id = TaskId('dl-stall-fail');
    await engine.create(
        id,
        DownloadRequest(
          source: const DownloadSource(
              initialUrl: 'http://127.0.0.1:1/refused'),
          output: OutputSpec(targetDirectory: outDir.path),
          maxConnections: 4,
        ));
    final done = Completer<EngineEvent>();
    engine.events(id).listen((e) {
      if (e is EngineCompleted || e is EngineFailed) done.complete(e);
    });
    await engine.start(id);
    final e = await done.future.timeout(const Duration(minutes: 1));
    expect(e, isA<EngineFailed>(),
        reason: 'dead server wedged in connecting — watchdog dead');
    expect(brisk.DownloadEngine.engineIsolates.containsKey(id.value),
        isFalse);
    expect(brisk.DownloadEngine.downloadItems.containsKey(id.value),
        isFalse);
  });
}
