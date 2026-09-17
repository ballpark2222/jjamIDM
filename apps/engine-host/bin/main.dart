import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_adapter_ffmpeg/freedm_adapter_ffmpeg.dart';
import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_engine_host/engine_host_server.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';

/// freedm-engine-host entry point.
///
/// Usage:
///   freedm-engine-host [--temp-root DIR] [--ytdlp PATH]
///                      [--ffmpeg PATH] [--data-dir DIR]
///
/// Speaks DownloadEngine Protocol v2 on stdin/stdout (NDJSON-RPC).
/// When media binaries are resolvable, media.probe/media.enqueue/
/// media.cancel are served in-process (yt-dlp + FFmpeg adapters).
Future<void> main(List<String> args) async {
  final sep = Platform.pathSeparator;
  var tempRoot =
      Directory('${Directory.systemTemp.path}${sep}freedm-engine');
  var dataDir =
      Directory('${Directory.systemTemp.path}${sep}freedm-engine');
  String? ytdlp = Platform.environment['FREEDM_YTDLP'];
  String? ffmpeg = Platform.environment['FREEDM_FFMPEG'];
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
    }
  }

  // Component lookup: packaged builds ship tools next to the exe in
  // components/; dev runs fall back to the workspace .tools dir.
  String? findTool(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final cand in [
      '$exeDir${sep}components$sep$name',
      '$exeDir$sep$name',
    ]) {
      if (File(cand).existsSync()) return cand;
    }
    var d = Directory.current.absolute;
    for (var i = 0; i < 8; i++) {
      final f = File('${d.parent.path}$sep.tools$sep$name');
      if (f.existsSync()) return f.path;
      final dev = File(
          '${d.path}$sep..$sep.tools$sep$name');
      if (dev.existsSync()) return dev.path;
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

  final server = EngineHostServer(
      engine: engine, tempRoot: tempRoot, media: media);
  await server.run(
      stdin.transform(utf8.decoder).transform(const LineSplitter()));
}
