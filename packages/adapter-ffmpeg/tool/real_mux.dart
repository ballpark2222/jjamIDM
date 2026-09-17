/// Real-FFmpeg verification — NOT a unit test; drives the actual
/// ffmpeg/ffprobe binaries under `.tools/ffmpeg-extract/`.
///
///   1. ffmpeg -version            (binary sanity)
///   2. synth 2s h264 video + aac audio via lavfi
///   3. FfmpegMuxer.mux → out.mp4  (real stream-copy mux)
///   4. ffprobe → verify 1 video + 1 audio stream
///
/// Run from anywhere:  dart run tool/real_mux.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_ffmpeg/freedm_adapter_ffmpeg.dart';
import 'package:freedm_media_api/freedm_media_api.dart';

Future<void> main() async {
  final root = _workspaceRoot();
  final ffbin = Directory('${root.parent.path}/.tools/'
      'ffmpeg-extract/ffmpeg-9.0.1-essentials_build/bin');
  final ffmpeg = '${ffbin.path}/ffmpeg.exe';
  final ffprobe = '${ffbin.path}/ffprobe.exe';
  if (!File(ffmpeg).existsSync()) {
    stderr.writeln('real ffmpeg not found at $ffmpeg');
    exit(2);
  }

  final muxer = FfmpegMuxer(command: [ffmpeg]);
  stdout.writeln('version: ${await muxer.version()}');

  final work = await Directory.systemTemp.createTemp('freedm_real_mux');
  try {
    final v = '${work.path}/v.mp4';
    final a = '${work.path}/a.m4a';
    await _run(ffmpeg, [
      '-y', '-f', 'lavfi',
      '-i', 'testsrc=duration=2:size=320x240:rate=15',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', v,
    ]);
    await _run(ffmpeg, [
      '-y', '-f', 'lavfi',
      '-i', 'sine=frequency=440:duration=2',
      '-c:a', 'aac', a,
    ]);

    final out = '${work.path}/out.mp4';
    final r = await muxer.mux(
        MuxStep(inputs: [v, a], outputFileName: out));
    if (!r.ok) {
      stderr.writeln('mux failed: ${r.error}');
      exit(1);
    }
    final outFile = File(out);
    if (!outFile.existsSync() || outFile.lengthSync() == 0) {
      stderr.writeln('mux produced no output');
      exit(1);
    }

    final probe = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'stream=codec_type,codec_name',
      '-of', 'json', out,
    ]);
    final streams = (jsonDecode(probe.stdout as String)
        ['streams'] as List)
        .map((s) => '${s['codec_type']}/${s['codec_name']}')
        .toList();
    stdout.writeln('streams: $streams  bytes: ${outFile.lengthSync()}');
    final ok = streams.any((s) => s.startsWith('video/')) &&
        streams.any((s) => s.startsWith('audio/'));
    stdout.writeln(ok ? 'REAL MUX: OK' : 'REAL MUX: BAD STREAMS');
    exit(ok ? 0 : 1);
  } finally {
    await work.delete(recursive: true);
  }
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    stderr.writeln('$exe ${args.join(' ')}\n${r.stderr}');
    exit(1);
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
