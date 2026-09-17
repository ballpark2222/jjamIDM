import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_test_server/freedm_test_server.dart';

void main() async {
  final fixture = await FixtureServer.start();
  final exe = String.fromEnvironment('YTDLP',
      defaultValue: '../../../.tools/yt-dlp.exe');
  final r = YtDlpResolver(command: [exe]);
  print('version: ${await r.version()}');
  final probe = await r.probe('${fixture.base}/hls/master.m3u8');
  print('supported=${probe.supported} title=${probe.title}');
  print('formats=${probe.formats.length}');
  for (final f in probe.formats.take(4)) {
    print('  ${f.formatId} ${f.ext} ${f.protocol} v=${f.hasVideo} a=${f.hasAudio}');
  }
  await fixture.close();
}
