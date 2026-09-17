/// Full real-world media pipeline — NOT a unit test; drives real
/// yt-dlp.exe + ffmpeg.exe against a live media page:
///
///   1. YtDlpResolver.probe → pick smallest audio + smallest video
///   2. YtDlpDownloader.download each (real bytes)
///   3. FfmpegMuxer.mux → single output container
///   4. ffprobe → verify video + audio streams in the result
///
/// This is the actual IDM-equivalent media flow end to end.
/// Run:  dart run tools/real-pipeline/real_pipeline.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_ffmpeg/freedm_adapter_ffmpeg.dart';
import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_media_api/freedm_media_api.dart';

const _page = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';

Future<void> main() async {
  final root = _workspaceRoot().parent.path;
  final ytdlp = '$root/.tools/yt-dlp.exe';
  final ffbin = '$root/.tools/'
      'ffmpeg-extract/ffmpeg-9.0.1-essentials_build/bin';
  final ffmpeg = '$ffbin/ffmpeg.exe';
  final ffprobe = '$ffbin/ffprobe.exe';
  for (final b in [ytdlp, ffmpeg, ffprobe]) {
    if (!File(b).existsSync()) {
      stderr.writeln('missing binary: $b');
      exit(2);
    }
  }

  final resolver = YtDlpResolver(command: [ytdlp]);
  final probe = await resolver.probe(_page);
  stdout.writeln('probe: ${probe.formats.length} formats');

  MediaFormat? smallest(bool Function(MediaFormat) test) {
    MediaFormat? pick;
    for (final f in probe.formats) {
      if (test(f) &&
          (pick == null ||
              (f.filesizeBytes ?? 1 << 60) <
                  (pick.filesizeBytes ?? 1 << 60))) {
        pick = f;
      }
    }
    return pick;
  }

  final audio = smallest((f) => f.hasAudio && !f.hasVideo);
  final video = smallest((f) => f.hasVideo && !f.hasAudio);
  if (audio == null || video == null) {
    stderr.writeln('no adaptive a/v pair found');
    exit(1);
  }
  stdout.writeln('audio=${audio.formatId} video=${video.formatId}');

  final work = await Directory.systemTemp.createTemp('freedm_pipe');
  try {
    final dl = YtDlpDownloader(command: [ytdlp]);
    final aPath = '${work.path}/a.${audio.ext}';
    final vPath = '${work.path}/v.${video.ext}';
    for (final (id, path) in [
      (audio.formatId, aPath),
      (video.formatId, vPath),
    ]) {
      final code = await dl.download(
          pageUrl: _page, outputPath: path, formatId: id,
          timeout: const Duration(minutes: 5));
      if (code != 0 || !File(path).existsSync()) {
        stderr.writeln('download failed for $id (code $code)');
        exit(1);
      }
      stdout.writeln('downloaded $id → ${File(path).lengthSync()}B');
    }

    final muxer = FfmpegMuxer(command: [ffmpeg]);
    final out = '${work.path}/final.mkv';
    final r = await muxer.mux(
        MuxStep(inputs: [vPath, aPath], outputFileName: out));
    if (!r.ok) {
      stderr.writeln('mux failed: ${r.error}');
      exit(1);
    }

    final p = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'stream=codec_type',
      '-of', 'json', out,
    ]);
    final types = (jsonDecode(p.stdout as String)['streams'] as List)
        .map((s) => s['codec_type'])
        .toList();
    stdout.writeln('muxed ${File(out).lengthSync()}B streams=$types');
    final ok = types.contains('video') && types.contains('audio');
    stdout.writeln(ok ? 'REAL PIPELINE: OK' : 'REAL PIPELINE: BAD');
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
