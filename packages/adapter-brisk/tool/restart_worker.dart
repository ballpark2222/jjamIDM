// Test helper: drives the Brisk adapter so the restart-resume test can
// exercise a REAL process boundary (Brisk keeps per-download state in
// static maps, so a true restart must be a fresh process).
//
//   dart tool/restart_worker.dart partial <url> <tempRoot> <outDir>
//       → starts a download, pauses at first progress, exits.
//   dart tool/restart_worker.dart finish <url> <tempRoot> <outDir>
//       → recreates the task with the same uid and runs to completion.
import 'dart:async';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';

const _id = TaskId('restart-task');

Future<void> main(List<String> args) async {
  final mode = args[0];
  final url = args[1];
  final tempRoot = Directory(args[2]);
  final outDir = Directory(args[3]);

  final engine = BriskEngineAdapter(tempRoot: tempRoot);
  await engine.create(
    _id,
    DownloadRequest(
      source: DownloadSource(initialUrl: url),
      output: OutputSpec(targetDirectory: outDir.path),
    ),
  );

  if (mode == 'partial') {
    // Die mid-download: watch the on-disk temp segment dir (engine
    // buffers progress reporting, but bytes hit disk continuously) and
    // exit once enough partial data exists — simulates a crash.
    await engine.start(_id);
    final tempDir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}restart-task${Platform.pathSeparator}restart-task');
    final sw = Stopwatch()..start();
    var size = 0;
    while (sw.elapsed < const Duration(minutes: 2)) {
      size = 0;
      if (await tempDir.exists()) {
        await for (final f in tempDir.list(recursive: true)) {
          if (f is File) size += await f.length();
        }
      }
      if (size > 256 * 1024) break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    stdout.writeln('DIED tempBytes=$size');
    exit(size > 0 ? 0 : 1);
  }

  final done = Completer<EngineEvent>();
  engine.events(_id).listen((e) {
    if (e is EngineCompleted || e is EngineFailed) done.complete(e);
  });
  await engine.start(_id);
  final e = await done.future.timeout(const Duration(minutes: 3));
  if (e is EngineCompleted) {
    stdout.writeln('DONE ${e.outputPath}');
    exit(0);
  }
  stdout.writeln('FAIL ${(e as EngineFailed).error}');
  exit(1);
}
