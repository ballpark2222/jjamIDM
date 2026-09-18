import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:freedm_media_api/freedm_media_api.dart';

/// MediaResolver over yt-dlp — the ONLY place yt-dlp argv is built
/// (design doc §18). Execution is out-of-process via an argument
/// vector; never a shell string.
///
/// [command] is an argv prefix (e.g. `['yt-dlp.exe']` or
/// `['python', 'yt-dlp.py']`) so tests can point at a shim.
final class YtDlpResolver implements MediaResolver {
  YtDlpResolver({
    required List<String> command,
    this.timeout = const Duration(minutes: 2),
    this.extraArgs = const [],
    this.environment,
  }) : _command = command;

  final List<String> _command;
  final List<String> extraArgs;
  final Duration timeout;

  /// Extra environment for the child process (test hooks, proxy vars).
  final Map<String, String>? environment;

  @override
  String get providerId => 'media.ytdlp';
  @override
  int get apiVersion => 1;

  /// Runs the resolver and captures stdout/stderr separately.
  /// Cancelling the returned operation kills the child process.
  Future<ProcessResult> _run(List<String> args,
      {Duration? timeout}) async {
    final proc = await Process.start(
      _command.first,
      [..._command.sublist(1), ...extraArgs, ...args],
      mode: ProcessStartMode.normal,
      environment: environment,
    );
    // Tracked so engine shutdown can kill the child — a probe that
    // outlives its parent is just wasted CPU forever.
    ChildProcessRegistry.track(proc);
    final out = StringBuffer();
    final err = StringBuffer();
    // allowMalformed: localized output can carry non-UTF-8 bytes on
    // Windows (system codepage); a strict decode would error the
    // stream and take the whole request down with it.
    const dec = Utf8Decoder(allowMalformed: true);
    final done = await Future.wait([
      proc.stdout.transform(dec).forEach(out.write),
      proc.stderr.transform(dec).forEach(err.write),
      proc.exitCode,
    ]).timeout(timeout ?? this.timeout, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      throw TimeoutException('yt-dlp timed out');
    });
    return ProcessResult(proc.pid, done[2] as int, '$out', '$err');
  }

  @override
  Future<String> version() async {
    final r = await _run(const ['--version'],
        timeout: const Duration(seconds: 15));
    if (r.exitCode != 0) {
      throw StateError('yt-dlp --version failed: ${r.stderr}');
    }
    return (r.stdout as String).trim();
  }

  @override
  Future<MediaProbe> probe(
    String pageUrl, {
    Map<String, String> headers = const {},
    String? cookieRef,
  }) async {
    final args = <String>[
      '-J', // single-video JSON dump
      '--no-playlist',
      '--no-warnings',
      ..._headerArgs(headers),
      pageUrl,
    ];
    ProcessResult r;
    try {
      r = await _run(args);
    } catch (_) {
      return const MediaProbe(supported: false);
    }
    if (r.exitCode != 0) return const MediaProbe(supported: false);
    final Map<String, Object?> j =
        (jsonDecode(r.stdout as String) as Map).cast<String, Object?>();
    return _parseProbe(j, pageUrl);
  }

  MediaProbe _parseProbe(Map<String, Object?> j, String pageUrl) {
    final formats = <MediaFormat>[];
    for (final f in (j['formats'] as List?) ?? const []) {
      final m = (f as Map).cast<String, Object?>();
      formats.add(MediaFormat(
        formatId: '${m['format_id'] ?? ''}',
        ext: '${m['ext'] ?? ''}',
        width: (m['width'] as num?)?.toInt(),
        height: (m['height'] as num?)?.toInt(),
        bitrateKbps: (m['tbr'] as num?)?.round(),
        filesizeBytes:
            (m['filesize'] as num?)?.toInt() ??
                (m['filesize_approx'] as num?)?.toInt(),
        hasVideo: m['vcodec'] != null && m['vcodec'] != 'none',
        hasAudio: m['acodec'] != null && m['acodec'] != 'none',
        protocol: '${m['protocol'] ?? 'https'}',
        label: m['format_note'] as String?,
        url: m['url'] as String?,
      ));
    }
    final subs = <MediaSubtitle>[];
    final rawSubs = j['subtitles'] ?? j['automatic_captions'];
    if (rawSubs is Map) {
      rawSubs.forEach((lang, list) {
        if (list is List && list.isNotEmpty) {
          final first = (list.first as Map).cast<String, Object?>();
          subs.add(MediaSubtitle(
            lang: '$lang',
            ext: '${first['ext'] ?? 'vtt'}',
            url: first['url'] as String?,
          ));
        }
      });
    }
    return MediaProbe(
      supported: formats.isNotEmpty,
      title: j['title'] as String?,
      durationSeconds: (j['duration'] as num?)?.toInt(),
      formats: formats,
      subtitles: subs,
      webpageUrl: j['webpage_url'] as String? ?? pageUrl,
    );
  }

  @override
  Future<MediaPlan> plan(MediaSelection selection,
      {Map<String, String> headers = const {}}) async {
    final info = await probe(selection.pageUrl, headers: headers);
    if (!info.supported) {
      throw StateError('unsupported media url ${selection.pageUrl}');
    }
    var name = _sanitize(
        selection.outputFileName ?? info.title ?? 'media');
    if (name.isEmpty) name = 'media';
    final byId = {for (final f in info.formats) f.formatId: f};
    final video = selection.videoFormatId != null
        ? byId[selection.videoFormatId]
        : null;
    final audio = selection.audioFormatId != null
        ? byId[selection.audioFormatId]
        : null;

    final steps = <MediaStep>[];
    // Progressive file (has both streams) or plain http → engine.
    // Split A/V or adaptive protocols → yt-dlp fetches itself.
    // The engine must fetch the format's resolved URL — pageUrl is
    // the HTML watch page, not the media bytes. Only bare http(s)
    // is a real file: http_dash_segments urls are manifests or
    // fragment bases, not the media itself.
    final direct = video != null &&
        (video.protocol == 'http' || video.protocol == 'https') &&
        (video.url ?? '').isNotEmpty &&
        audio == null;
    if (direct && video.hasAudio) {
      steps.add(EngineDownloadStep(
        url: video.url!,
        outputFileName: '$name.${video.ext}',
        headers: headers,
      ));
      // Selected subs ride the engine too — role 'subtitle' routes
      // their outputs into run.subtitles for the attach stage.
      // Skip formats ffmpeg can't transcode into the container.
      const attachable = {'vtt', 'srt', 'ass', 'ssa', 'ttml'};
      final wanted = selection.subtitleLangs.toSet();
      for (final s in info.subtitles) {
        if (wanted.contains(s.lang) &&
            attachable.contains(s.ext.toLowerCase()) &&
            (s.url ?? '').isNotEmpty) {
          steps.add(EngineDownloadStep(
            url: s.url!,
            outputFileName:
                '$name.${_sanitize(s.lang)}.${_sanitize(s.ext)}',
            role: 'subtitle',
            headers: headers,
          ));
        }
      }
      return MediaPlan(steps: steps, finalFileName: '$name.${video.ext}');
    }
    // Component step — yt-dlp resolves + downloads the format graph.
    final fmt = [video?.formatId, audio?.formatId]
        .whereType<String>()
        .join('+');
    steps.add(ComponentDownloadStep(
      componentId: 'tool.ytdlp',
      outputFileName: name,
      formatId: fmt.isEmpty ? null : fmt,
    ));
    return MediaPlan(steps: steps, finalFileName: name);
  }

  List<String> _headerArgs(Map<String, String> headers) => [
        for (final e in headers.entries)
          ...['--add-headers', '${e.key}: ${e.value}'],
      ];

  static String _sanitize(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\.\.+'), '_')
      .trim();
}
