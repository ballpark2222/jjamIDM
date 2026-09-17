import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Out-of-process yt-dlp downloader for ComponentDownloadSteps
/// (HLS/DASH/split streams the engine can't Range-fetch). Argv only —
/// URLs never go through a shell (design doc §18).
///
/// Progress lines on stdout/stderr are parsed into simple percent
/// callbacks; cancellation kills the process group.
final class YtDlpDownloader {
  YtDlpDownloader({required List<String> command, this.environment})
      : _command = command;

  final List<String> _command;
  final Map<String, String>? environment;

  /// Downloads [url] (optionally a `v+a` format pair) to
  /// [outputPath]. Returns the process exit code; [onPercent] gets
  /// 0..100 as yt-dlp reports it.
  Future<int> download({
    required String url,
    required String outputPath,
    String? format,
    Map<String, String> headers = const {},
    List<String> subtitleLangs = const [],
    void Function(double percent)? onPercent,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final args = <String>[
      '--newline',
      '--no-playlist',
      '-o', outputPath,
      if (format != null && format.isNotEmpty) ...['-f', format],
      for (final e in headers.entries) ...['--add-headers', '${e.key}: ${e.value}'],
      if (subtitleLangs.isNotEmpty) ...[
        '--write-subs',
        '--sub-langs', subtitleLangs.join(','),
      ],
      url,
    ];
    final proc = await Process.start(
      _command.first,
      [..._command.sublist(1), ...args],
      mode: ProcessStartMode.normal,
      environment: environment,
    );
    final timer = Timer(timeout, () => proc.kill(ProcessSignal.sigkill));
    final re = RegExp(r'\[download\]\s+([\d.]+)%');
    void scan(String line) {
      final m = re.firstMatch(line);
      if (m != null) onPercent?.call(double.parse(m.group(1)!));
    }

    final subs = [
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(scan),
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(scan),
    ];
    final code = await proc.exitCode;
    timer.cancel();
    for (final s in subs) await s.cancel();
    return code;
  }
}
