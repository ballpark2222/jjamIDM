import 'dart:async';
import 'dart:io';

import 'package:freedm_media_api/freedm_media_api.dart';

/// MediaMuxer over FFmpeg — the ONLY place ffmpeg argv is built
/// (design doc §18). Out-of-process argv execution, no shell.
///
/// [command] is an argv prefix (e.g. `['ffmpeg.exe']` or a shim).
final class FfmpegMuxer implements MediaMuxer {
  FfmpegMuxer({
    required List<String> command,
    this.timeout = const Duration(minutes: 10),
  }) : _command = command;

  final List<String> _command;
  final Duration timeout;

  @override
  String get providerId => 'media.ffmpeg';

  Future<ProcessResult> _run(List<String> args) async {
    final proc = await Process.start(
      _command.first,
      [..._command.sublist(1), ...args],
      mode: ProcessStartMode.normal,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await Future.wait([
      proc.stderr.transform(const SystemEncoding().decoder)
          .forEach(err.write),
      proc.stdout.transform(const SystemEncoding().decoder)
          .forEach(out.write),
      proc.exitCode,
    ]).timeout(timeout, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      throw TimeoutException('ffmpeg timed out');
    }).then((v) => v[2] as int);
    return ProcessResult(proc.pid, code, '$out', '$err');
  }

  @override
  Future<String> version() async {
    final r = await _run(const ['-version']);
    if (r.exitCode != 0) {
      throw StateError('ffmpeg -version failed: ${r.stderr}');
    }
    return (r.stdout as String).split('\n').first.trim();
  }

  @override
  Future<MuxResult> mux(MuxStep step, {String workDir = '.'}) async {
    if (step.inputs.isEmpty) {
      return const MuxResult(ok: false, error: 'no inputs');
    }
    final args = <String>[
      '-y',
      for (final i in step.inputs) ...['-i', i],
      for (final s in step.subtitleInputs) ...['-i', s],
      '-c', 'copy',
      '-c:s', 'mov_text',
      step.outputFileName,
    ];
    try {
      final r = await _run(args);
      return r.exitCode == 0
          ? MuxResult(ok: true, outputPath: step.outputFileName)
          : MuxResult(ok: false, error: r.stderr as String);
    } catch (e) {
      return MuxResult(ok: false, error: '$e');
    }
  }

  @override
  Future<MuxResult> attachSubtitles(
    String videoPath,
    List<String> subtitlePaths, {
    String? outputPath,
  }) async {
    if (subtitlePaths.isEmpty) {
      return const MuxResult(ok: false, error: 'no subtitles');
    }
    final out = outputPath ??
        videoPath.replaceFirst(
            RegExp(r'\.[A-Za-z0-9]+$'), '.subtitled.mp4');
    return mux(MuxStep(
      inputs: [videoPath],
      outputFileName: out,
      subtitleInputs: subtitlePaths,
    ));
  }
}
