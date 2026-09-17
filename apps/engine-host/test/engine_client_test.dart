import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_host/engine_client.dart';
import 'package:freedm_test_server/freedm_test_server.dart';
import 'package:test/test.dart';

/// E2E: EngineHostClient ↔ real engine-host process ↔ fixture server.
/// Exercises the protocol client the desktop app uses.
void main() {
  late FixtureServer fixture;
  late Directory outDir;
  late EngineHostClient client;

  setUpAll(() async {
    fixture = await FixtureServer.start();
  });
  tearDownAll(() async {
    await fixture.close();
  });

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('ehc');
    final temp = await Directory.systemTemp.createTemp('ehc-t');
    // `dart test` may run from the package dir or the workspace
    // root — find the engine-host entry point by walking up.
    final sep = Platform.pathSeparator;
    var dir = Directory.current;
    String? hostMain;
    for (var i = 0; i < 8; i++) {
      for (final rel in [
        'apps${sep}engine-host${sep}bin${sep}main.dart',
        'bin${sep}main.dart'
      ]) {
        final f = File('${dir.path}$sep$rel');
        if (f.existsSync() && f.path.contains('engine-host')) {
          hostMain = f.path;
          break;
        }
        if (f.existsSync() &&
            File('${dir.path}${sep}pubspec.yaml')
                .readAsStringSync()
                .contains('freedm_engine_host')) {
          hostMain = f.path;
          break;
        }
      }
      if (hostMain != null) break;
      dir = dir.parent;
    }
    if (hostMain == null) {
      throw StateError('engine-host bin/main.dart not found');
    }
    client = await EngineHostClient.spawn([
      Platform.resolvedExecutable,
      hostMain,
      '--temp-root',
      temp.path,
    ]);
  });
  tearDown(() async {
    await client.shutdown();
    for (var i = 0; i < 20; i++) {
      try {
        await outDir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('hello negotiates protocol v1 + capabilities', () async {
    final caps = await client.capabilities();
    expect(caps.segmentedDownload, isTrue);
    expect(caps.resume, isTrue);
  });

  test('probe reports size and range support', () async {
    final p = await client.probe(DownloadRequest(
      source: DownloadSource(initialUrl: '${fixture.base}/file-range'),
      output: OutputSpec(targetDirectory: outDir.path),
    ));
    expect(p.supported, isTrue);
    expect(p.totalBytes, FixtureServer.defaultLength);
    expect(p.acceptsRanges, isTrue);
  });

  test('full download: progress events + file lands on disk', () async {
    const id = TaskId('e2e-1');
    final req = DownloadRequest(
      source: DownloadSource(initialUrl: '${fixture.base}/file-range'),
      output: OutputSpec(targetDirectory: outDir.path),
    );
    await client.create(id, req);
    final events = client.events(id);
    final done = Completer<EngineCompleted>();
    var sawProgress = false;
    final sub = events.listen((e) {
      if (e is EngineProgress && e.receivedBytes > 0) {
        sawProgress = true;
      }
      if (e is EngineCompleted && !done.isCompleted) done.complete(e);
    });
    await client.start(id);
    final completed = await done.future.timeout(
        const Duration(seconds: 60));

    final out = File(completed.outputPath!);
    expect(out.existsSync(), isTrue);
    final bytes = await out.readAsBytes();
    expect(sha256.convert(bytes).toString(),
        sha256.convert(FixtureServer.fixtureBytes(
            FixtureServer.defaultLength)).toString());
    expect(sawProgress, isTrue);
    await sub.cancel();
  });
}
