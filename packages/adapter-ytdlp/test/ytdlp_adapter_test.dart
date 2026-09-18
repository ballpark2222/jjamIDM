import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_ytdlp/freedm_adapter_ytdlp.dart';
import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:test/test.dart';

void main() {
  // `dart test` may run from the package dir or the workspace root —
  // walk up until we find the workspace marker, then use the known
  // package layout.
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !File('${dir.path}/pubspec.yaml')
          .readAsStringSync()
          .contains('freedm_workspace')) {
    dir = dir.parent;
  }
  final shim = [
    Platform.resolvedExecutable,
    '${dir.path}/packages/adapter-ytdlp/tool/fake_ytdlp.dart',
  ];
  late Directory tmp;
  late File argvLog;
  late YtDlpResolver resolver;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ytdlp-t');
    argvLog = File('${tmp.path}\\argv.log');
    resolver = YtDlpResolver(
      command: shim,
      environment: {'FAKE_YTDLP_ARGV_LOG': argvLog.path},
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<List<List<String>>> loggedArgv() async =>
      (await argvLog.readAsLines())
          .map((l) => (jsonDecode(l) as List).cast<String>())
          .toList();

  test('probe normalizes formats + subtitles', () async {
    final p = await resolver.probe('http://fixture/v');
    expect(p.supported, isTrue);
    expect(p.title, 'Fixture Video');
    expect(p.formats.length, 4);
    final p360 = p.formats.firstWhere((f) => f.formatId == 'p360');
    expect(p360.hasAudio, isTrue);
    expect(p360.hasVideo, isTrue);
    expect(p.subtitles.map((s) => s.lang).toSet(), {'en', 'ko'});
  });

  test('plan: progressive http format → engine step', () async {
    final plan = await resolver.plan(const MediaSelection(
      pageUrl: 'http://fixture/v',
      videoFormatId: 'p360',
      outputFileName: 'my video/ weird:name',
    ));
    expect(plan.steps.single, isA<EngineDownloadStep>());
    expect(plan.finalFileName, isNot(contains('/')));
    expect(plan.finalFileName, isNot(contains(':')));
  });



  test('plan: engine step fetches the resolved format url, '
      'not the page url', () async {
    final plan = await resolver.plan(const MediaSelection(
      pageUrl: 'http://fixture/v',
      videoFormatId: 'p360',
    ));
    final step = plan.steps.single as EngineDownloadStep;
    // The page url is an HTML watch page — downloading it as .mp4
    // was the bug. The engine must get the format's stream url.
    expect(step.url, 'https://cdn.fixture/vid360.mp4?sig=x');
    expect(step.url, isNot('http://fixture/v'));
  });

  test('plan: http format without a resolved url falls back to '
      'component step', () async {
    final plan = await resolver.plan(const MediaSelection(
      pageUrl: 'http://fixture/v',
      videoFormatId: 'p144', // http+audio but url is absent
    ));
    expect(plan.steps.single, isA<ComponentDownloadStep>());
  });

  test('plan: split/adaptive → component step (yt-dlp fetches)',
      () async {
    final plan = await resolver.plan(const MediaSelection(
      pageUrl: 'http://fixture/v',
      videoFormatId: 'v720', // hls, no audio
      audioFormatId: 'a128',
    ));
    final step = plan.steps.single;
    expect(step, isA<ComponentDownloadStep>());
    expect((step as ComponentDownloadStep).formatId, 'v720+a128');
  });

  test('version probe', () async {
    expect(await resolver.version(), '2026.09.17');
  });

  test('downloader reports progress and writes output', () async {
    final dl = YtDlpDownloader(
      command: shim,
      environment: {'FAKE_YTDLP_ARGV_LOG': argvLog.path},
    );
    final out = '${tmp.path}\\out.bin';
    final pcts = <double>[];
    final code = await dl.download(
      pageUrl: 'http://fixture/v',
      outputPath: out,
      formatId: 'v720+a128',
      onProgress: pcts.add,
    );
    expect(code, 0);
    expect(pcts.first, 0);
    expect(pcts.last, 1.0);
    expect(File(out).lengthSync(), 1024);
  });

  test('bare outputPath is passed as name.%(ext)s so yt-dlp fills '
      'the real container extension', () async {
    final dl = YtDlpDownloader(
      command: shim,
      environment: {'FAKE_YTDLP_ARGV_LOG': argvLog.path},
    );
    final code = await dl.download(
      pageUrl: 'http://fixture/v',
      outputPath: '${tmp.path}\\bare name',
      formatId: 'v720+a128',
    );
    expect(code, 0);
    final argv = await loggedArgv();
    final i = argv.last.indexOf('-o');
    expect(argv.last[i + 1], '${tmp.path}\\bare name.%(ext)s');
    // Fake substitutes mkv like a merged v+a download — the produced
    // artifact carries a real extension.
    expect(File('${tmp.path}\\bare name.mkv').existsSync(), isTrue);
  });

  test('headers travel as --add-headers argv pairs, never a shell',
      () async {
    final dl = YtDlpDownloader(
      command: shim,
      environment: {'FAKE_YTDLP_ARGV_LOG': argvLog.path},
    );
    await dl.download(
      pageUrl: 'http://fixture/v',
      outputPath: '${tmp.path}\\h.bin',
      headers: const {'Cookie': 'a=b; c=d', 'Authorization': 'Bearer x'},
    );
    final argv = await loggedArgv();
    final last = argv.last;
    final i = last.indexOf('--add-headers');
    expect(i, greaterThan(0));
    expect(last[i + 1], 'Cookie: a=b; c=d');
    expect(last, containsAllInOrder(
        ['--add-headers', 'Authorization: Bearer x']));
  });
}
