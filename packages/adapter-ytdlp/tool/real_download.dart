/// Real yt-dlp download verification — NOT a unit test; drives the
/// actual yt-dlp.exe against a live media page.
///
///   1. YtDlpResolver.probe → pick the smallest progressive format
///   2. YtDlpDownloader.download → real bytes to a temp file
///   3. verify: exit 0, file exists, non-trivial size, progress
///      callbacks fired
///
/// Run:  dart run tool/real_download.dart
library;

import 'dart:io';

import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_media_api/freedm_media_api.dart';

const _page = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';

Future<void> main() async {
  final root = _workspaceRoot();
  final exe = '${root.parent.path}/.tools/yt-dlp.exe';
  if (!File(exe).existsSync()) {
    stderr.writeln('yt-dlp.exe not found at $exe');
    exit(2);
  }

  final resolver = YtDlpResolver(command: [exe]);
  stdout.writeln('probing $_page ...');
  final probe = await resolver.probe(_page);
  stdout.writeln('formats: ${probe.formats.length}');

  // smallest progressive (v+a in one file) else smallest overall
  MediaFormat? pick;
  for (final f in probe.formats) {
    if (f.hasVideo && f.hasAudio) {
      if (pick == null ||
          (f.filesizeBytes ?? 1 << 60) <
              (pick.filesizeBytes ?? 1 << 60)) {
        pick = f;
      }
    }
  }
  pick ??= probe.formats.reduce((a, b) =>
      (a.filesizeBytes ?? 1 << 60) <= (b.filesizeBytes ?? 1 << 60)
          ? a
          : b);
  stdout.writeln('picked ${pick.formatId} v=${pick.hasVideo} '
      'a=${pick.hasAudio} size=${pick.filesizeBytes}');

  final work = await Directory.systemTemp.createTemp('freedm_ytdlp');
  try {
    final out = '${work.path}/dl.%(ext)s';
    var last = 0.0;
    var ticks = 0;
    final dl = YtDlpDownloader(command: [exe]);
    final code = await dl.download(
      pageUrl: _page,
      outputPath: out,
      formatId: pick.formatId,
      onProgress: (p) {
        ticks++;
        if (p - last >= 0.1 || p >= 1.0) {
          last = p;
          stdout.writeln('  progress ${(p * 100).toStringAsFixed(0)}%');
        }
      },
      timeout: const Duration(minutes: 5),
    );
    if (code != 0) {
      stderr.writeln('yt-dlp exited $code');
      exit(1);
    }
    final files = work.listSync().whereType<File>().toList();
    final got = files.isEmpty ? 0 : files.first.lengthSync();
    stdout.writeln('output: ${files.map((f) => f.path).toList()}'
        ' bytes=$got progressTicks=$ticks');
    final ok = got > 10000 && ticks > 0;
    stdout.writeln(ok ? 'REAL DOWNLOAD: OK' : 'REAL DOWNLOAD: BAD');
    exit(ok ? 0 : 1);
  } finally {
    await work.delete(recursive: true);
  }
}

Directory _workspaceRoot() {
  var d = Directory.current.absolute;
  while (true) {
    final f = File('${d.path}/pubspec.yaml');
    if (f.existsSync() &&
        f.readAsStringSync().contains('freedm_workspace')) {
      return d;
    }
    final p = d.parent;
    if (p.path == d.path) {
      stderr.writeln('workspace root not found');
      exit(2);
    }
    d = p;
  }
}
