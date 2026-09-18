import 'dart:async';
import 'dart:convert';
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
    this.environment,
  }) : _command = command;

  final List<String> _command;
  final Duration timeout;

  /// Extra environment for the child process (test hooks, proxies).
  final Map<String, String>? environment;

  @override
  String get providerId => 'media.ffmpeg';

  Future<ProcessResult> _run(List<String> args) async {
    final proc = await Process.start(
      _command.first,
      [..._command.sublist(1), ...args],
      mode: ProcessStartMode.normal,
      environment: environment,
    );
    // Tracked so engine shutdown can kill the child — an orphaned
    // ffmpeg keeps transcoding forever with no parent to stop it.
    ChildProcessRegistry.track(proc);
    final out = StringBuffer();
    final err = StringBuffer();
    // FFmpeg writes UTF-8; allowMalformed so a stray non-UTF-8 byte
    // can't error the stream and kill the request zone.
    const dec = Utf8Decoder(allowMalformed: true);
    final code = await Future.wait([
      proc.stderr.transform(dec).forEach(err.write),
      proc.stdout.transform(dec).forEach(out.write),
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

  /// MuxStep inputs/outputs are usually bare filenames that live in
  /// the coordinator's per-task workDir. Resolve them explicitly so
  /// ffmpeg's working directory is irrelevant, and return the real
  /// output path — callers treat MuxResult.outputPath as absolute.
  static bool _isAbs(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  static String _resolve(String path, String workDir) =>
      _isAbs(path) || workDir == '.' || workDir.isEmpty
          ? path
          : '$workDir${Platform.pathSeparator}$path';

  /// mov_text is the only subtitle codec legal in mp4/mov — in mkv
  /// ffmpeg must transcode to srt (and webm only accepts webvtt).
  static String _subCodecFor(String outPath) {
    final dot = outPath.lastIndexOf('.');
    final ext =
        dot < 0 ? '' : outPath.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'mkv' || 'mka' => 'srt',
      'webm' => 'webvtt',
      _ => 'mov_text',
    };
  }

  @override
  Future<MuxResult> mux(MuxStep step, {String workDir = '.'}) async {
    if (step.inputs.isEmpty) {
      return const MuxResult(ok: false, error: 'no inputs');
    }
    final outPath = _resolve(step.outputFileName, workDir);
    final total =
        step.inputs.length + step.subtitleInputs.length;
    final args = <String>[
      '-y',
      for (final i in step.inputs) ...['-i', _resolve(i, workDir)],
      for (final s in step.subtitleInputs) ...['-i', _resolve(s, workDir)],
      // Without -map ffmpeg auto-selects ONE stream per type —
      // a second subtitle input would silently never land.
      for (var i = 0; i < total; i++) ...['-map', '$i'],
      '-c', 'copy',
      '-c:s', _subCodecFor(outPath),
      outPath,
    ];
    try {
      final r = await _run(args);
      return r.exitCode == 0
          ? MuxResult(ok: true, outputPath: outPath)
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
    // Keep the input's container — forcing .mp4 mislabels an mkv
    // (and mov_text isn't a legal subtitle codec there anyway).
    final m = RegExp(r'\.[A-Za-z0-9]+$').firstMatch(videoPath);
    final out = outputPath ??
        videoPath.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'),
            '.subtitled${m?.group(0) ?? '.mp4'}');
    return mux(MuxStep(
      inputs: [videoPath],
      outputFileName: out,
      subtitleInputs: subtitlePaths,
    ));
  }
}
