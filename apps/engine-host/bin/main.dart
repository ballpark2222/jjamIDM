import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_adapter_ffmpeg/freedm_adapter_ffmpeg.dart';
import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_engine_host/engine_host_server.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';

/// freedm-engine-host entry point.
///
/// Usage:
///   freedm-engine-host [--temp-root DIR] [--ytdlp PATH]
///                      [--ffmpeg PATH] [--data-dir DIR]
///                      [--queue DIR] [--max-concurrent N]
///
/// Speaks DownloadEngine Protocol v2 on stdin/stdout (NDJSON-RPC).
/// When media binaries are resolvable, media.probe/media.enqueue/
/// media.cancel/media.pause/media.resume are served in-process.
///
/// With --queue DIR, task.* calls route through the application
/// DownloadScheduler (concurrency, priority, retry, task repo in
/// DIR) — used by the browser native host which has no control
/// plane of its own. The desktop app runs its own scheduler and
/// spawns this host without --queue.
Future<void> main(List<String> args) async {
  final sep = Platform.pathSeparator;
  var tempRoot =
      Directory('${Directory.systemTemp.path}${sep}freedm-engine');
  var dataDir =
      Directory('${Directory.systemTemp.path}${sep}freedm-engine');
  String? ytdlp = Platform.environment['FREEDM_YTDLP'];
  String? ffmpeg = Platform.environment['FREEDM_FFMPEG'];
  String? queueDir;
  var maxConcurrent = 3;
  for (var i = 0; i + 1 < args.length; i++) {
    switch (args[i]) {
      case '--temp-root':
        tempRoot = Directory(args[i + 1]);
      case '--data-dir':
        dataDir = Directory(args[i + 1]);
      case '--ytdlp':
        ytdlp = args[i + 1];
      case '--ffmpeg':
        ffmpeg = args[i + 1];
      case '--queue':
        queueDir = args[i + 1];
      case '--max-concurrent':
        maxConcurrent = int.tryParse(args[i + 1]) ?? 3;
    }
  }

  /// `.tools` probe: flat `.tools/<name>` first, then one level of
  /// vendor dirs (`<vendor>/<name>`, `<vendor>/bin/<name>`) and a
  /// versioned inner dir (`<vendor>/<ver>/bin/<name>`).
  String? findUnderTools(Directory toolsDir, String name) {
    if (!toolsDir.existsSync()) return null;
    final flat = File('${toolsDir.path}$sep$name');
    if (flat.existsSync()) return flat.path;
    for (final vendor in toolsDir.listSync()) {
      if (vendor is! Directory) continue;
      for (final cand in [
        '${vendor.path}$sep$name',
        '${vendor.path}${sep}bin$sep$name',
      ]) {
        if (File(cand).existsSync()) return cand;
      }
      for (final inner in vendor.listSync()) {
        if (inner is Directory &&
            File('${inner.path}${sep}bin$sep$name').existsSync()) {
          return '${inner.path}${sep}bin$sep$name';
        }
      }
    }
    return null;
  }

  // Component lookup: packaged builds ship tools next to the exe in
  // components/ (or one level up — the RC puts the browser engine in
  // desktop/ and tools in <rc>/components); dev runs fall back to the
  // workspace .tools dir, including nested vendor dists like
  // .tools/ffmpeg-extract/<ver>/bin/ffmpeg.exe.
  String? findTool(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final cand in [
      '$exeDir${sep}components$sep$name',
      '$exeDir$sep$name',
      '$exeDir$sep..${sep}components$sep$name',
    ]) {
      if (File(cand).existsSync()) return cand;
    }
    var d = Directory.current.absolute;
    for (var i = 0; i < 8; i++) {
      for (final toolsDir in [
        Directory('${d.parent.path}$sep.tools'),
        Directory('${d.path}$sep..$sep.tools'),
      ]) {
        final hit = findUnderTools(toolsDir, name);
        if (hit != null) return hit;
      }
      d = d.parent;
    }
    return null;
  }

  ytdlp ??= findTool('yt-dlp.exe');
  ffmpeg ??= findTool('ffmpeg.exe');

  final engine = BriskEngineAdapter(
    tempRoot: tempRoot,
    // Per-task engine logs land in <tempRoot>/<taskId>/ so a failed
    // download leaves diagnosable evidence (default tempRoot is
    // %TEMP%\freedm-engine).
    engineLogging: true,
  );

  MediaDownloadCoordinator? media;
  if (ytdlp != null && ffmpeg != null) {
    final repo = await JsonTaskRepository.open(
        Directory('${dataDir.path}${sep}media-tasks'));
    // yt-dlp locates ffmpeg via PATH for HLS/DASH muxing — extend
    // it with the ffmpeg dir without disturbing the rest of env.
    final toolPath =
        '${File(ffmpeg).parent.path}${Platform.isWindows ? ';' : ':'}'
        '${Platform.environment['PATH'] ?? ''}';
    final env = {'PATH': toolPath};
    media = MediaDownloadCoordinator(
      engine: engine,
      repository: repo,
      eventBus: InMemoryEventBus(),
      resolver: YtDlpResolver(command: [ytdlp], environment: env),
      muxer: FfmpegMuxer(command: [ffmpeg]),
      componentDownloaders: {
        'tool.ytdlp':
            YtDlpDownloader(command: [ytdlp], environment: env),
      },
    );
  } else {
    stderr.writeln(
        'engine-host: media tools not found (ytdlp=$ytdlp '
        'ffmpeg=$ffmpeg) — media.* methods disabled');
  }

  DownloadScheduler? scheduler;
  if (queueDir != null) {
    final repo =
        await JsonTaskRepository.open(Directory(queueDir));
    var seq = 0;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    scheduler = DownloadScheduler(
      engine: engine,
      repository: repo,
      eventBus: InMemoryEventBus(),
      // Callers pass explicit taskIds; this only covers gaps.
      idGenerator: () => TaskId('q$stamp-${seq++}'),
      maxConcurrent: maxConcurrent,
    );
    await scheduler.recover();
  }
  // Construct the server BEFORE media recovery: its constructor
  // subscribes to media.changes (a broadcast — emissions with no
  // listener are dropped), so recovered/failed task transitions
  // only reach the client when the subscription already exists.
  final server = EngineHostServer(
      engine: engine, tempRoot: tempRoot,
      media: media, scheduler: scheduler);
  // Mark interrupted media tasks regardless of queue mode — in-memory
  // run state is gone after any restart.
  await media?.recover();

  await server.run(
      stdin.transform(utf8.decoder).transform(const LineSplitter()));
  // stdin EOF = the control plane is gone. Land queued persistence
  // first (bounded — a wedged FS must not hang the exit), or a
  // transition in the final debounce window resurrects next launch.
  try {
    await scheduler?.flush().timeout(const Duration(seconds: 5));
    await media?.flush().timeout(const Duration(seconds: 5));
  } catch (_) {}
  // Without an explicit exit the event loop stays alive on open
  // engine sockets/isolates — an orphaned host keeps writing shared
  // segment temp files while the next launch's recovery
  // re-dispatches the same tasks.
  exit(0);
}
