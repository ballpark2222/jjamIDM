import 'dart:convert';
import 'dart:io';

/// Fake yt-dlp for adapter tests. Behaviours:
///   --version              -> prints a version line
///   -J <url>               -> prints canned probe JSON
///   --newline -o <out> <u> -> writes a file, emits [download] N% lines
/// Always appends its argv to FAKE_YTDLP_ARGV_LOG when set.
Future<void> main(List<String> args) async {
  final log = Platform.environment['FAKE_YTDLP_ARGV_LOG'];
  if (log != null) {
    File(log).writeAsStringSync('${jsonEncode(args)}\n',
        mode: FileMode.append);
  }
  if (args.contains('--version')) {
    stdout.writeln('2026.09.17');
    return;
  }
  if (args.contains('-J')) {
    stdout.writeln(jsonEncode({
      'id': 'abc',
      'title': 'Fixture Video',
      'webpage_url': args.last,
      'duration': 8,
      'formats': [
        {
          'format_id': 'p360', 'ext': 'mp4', 'height': 360,
          'vcodec': 'avc1', 'acodec': 'mp4a', 'protocol': 'https',
          'tbr': 500, 'filesize': 1048576,
          'url': 'https://cdn.fixture/vid360.mp4?sig=x',
        },
        {
          'format_id': 'v720', 'ext': 'mp4', 'height': 720,
          'vcodec': 'avc1', 'acodec': 'none', 'protocol': 'm3u8_native',
          'tbr': 2500,
          'url': 'https://cdn.fixture/v720.m3u8',
        },
        {
          'format_id': 'a128', 'ext': 'm4a',
          'vcodec': 'none', 'acodec': 'aac', 'protocol': 'https',
          'tbr': 128,
          'url': 'https://cdn.fixture/a128.m4a?sig=y',
        },
        {
          // http+audio but no resolved url — yt-dlp emits this for
          // storyboard/redirect formats; must not engine-download.
          'format_id': 'p144', 'ext': 'mp4', 'height': 144,
          'vcodec': 'avc1', 'acodec': 'mp4a', 'protocol': 'https',
          'tbr': 90,
        },
      ],
      'subtitles': {
        'en': [{'ext': 'vtt', 'url': 'http://x/en.vtt'}],
        'ko': [{'ext': 'vtt', 'url': 'http://x/ko.vtt'}],
      },
    }));
    return;
  }
  final o = args.indexOf('-o');
  if (o >= 0) {
    // Real yt-dlp replaces %(ext)s with the chosen container ext —
    // substitute 'mkv' the way a merged v+a download would land.
    final out = File(args[o + 1].replaceAll('%(ext)s', 'mkv'));
    for (var pct = 0; pct <= 100; pct += 25) {
      stdout.writeln('[download] $pct.0% of ~1.00MiB');
    }
    out.writeAsBytesSync(List.filled(1024, 0x5A));
    return;
  }
  stderr.writeln('fake-ytdlp: unhandled args $args');
  exit(64);
}
