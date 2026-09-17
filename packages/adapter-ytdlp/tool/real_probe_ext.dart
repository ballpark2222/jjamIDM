import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';

void main() async {
  const exe = String.fromEnvironment('YTDLP',
      defaultValue: '../../../.tools/yt-dlp.exe');
  const url = String.fromEnvironment('URL',
      defaultValue:
          'https://test-videos.co.uk/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4');
  final r = YtDlpResolver(command: [exe]);
  try {
    final probe = await r.probe(url).timeout(const Duration(seconds: 90));
    print('supported=${probe.supported} title=${probe.title}');
    for (final f in probe.formats) {
      print('  ${f.formatId} ${f.ext} ${f.protocol} '
          'v=${f.hasVideo} a=${f.hasAudio} ${f.filesizeBytes}b');
    }
  } catch (e) {
    print('probe failed (network): $e');
  }
}
