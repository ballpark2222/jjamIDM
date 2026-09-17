import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_ffmpeg/freedm_adapter_ffmpeg.dart';
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
    '${dir.path}/packages/adapter-ffmpeg/tool/fake_ffmpeg.dart',
  ];
  late FfmpegMuxer muxer;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ffmpeg-t');
    muxer = FfmpegMuxer(command: shim);
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('version probe', () async {
    expect(await muxer.version(), contains('ffmpeg version fake-1.0'));
  });

  test('mux concatenates inputs into the output (argv built)', () async {
    final a = File('${tmp.path}\\v.mp4')..writeAsBytesSync([1, 2, 3]);
    final b = File('${tmp.path}\\a.m4a')..writeAsBytesSync([4, 5]);
    final out = '${tmp.path}\\out.mp4';
    final r = await muxer.mux(MuxStep(
      inputs: [a.path, b.path],
      outputFileName: out,
    ));
    expect(r.ok, isTrue, reason: '${r.error}');
    expect(File(out).readAsBytesSync(), [1, 2, 3, 4, 5]);
  });

  test('attachSubtitles names a subtitled output', () async {
    final v = File('${tmp.path}\\movie.mp4')..writeAsBytesSync([9]);
    final s = File('${tmp.path}\\en.vtt')..writeAsBytesSync([8]);
    final r = await muxer.attachSubtitles(v.path, [s.path]);
    expect(r.ok, isTrue, reason: '${r.error}');
    expect(File('${tmp.path}\\movie.subtitled.mp4').existsSync(), isTrue);
  });

  test('attachSubtitles keeps the input container and picks a '
      'container-legal subtitle codec', () async {
    final argvLog = File('${tmp.path}\\argv.log');
    final m = FfmpegMuxer(
        command: shim,
        environment: {'FAKE_FFMPEG_ARGV_LOG': argvLog.path});
    final v = File('${tmp.path}\\movie.mkv')..writeAsBytesSync([9]);
    final s = File('${tmp.path}\\en.vtt')..writeAsBytesSync([8]);
    final r = await m.attachSubtitles(v.path, [s.path]);
    expect(r.ok, isTrue, reason: '${r.error}');
    // mkv in → mkv out (mov_text would be rejected there).
    expect(
        File('${tmp.path}\\movie.subtitled.mkv').existsSync(),
        isTrue);
    final last = (await argvLog.readAsLines())
        .map((l) => (jsonDecode(l) as List).cast<String>())
        .last;
    expect(last[last.indexOf('-c:s') + 1], 'srt');
  });

  test('mux resolves bare inputs/output against workDir', () async {
    // The coordinator passes bare filenames + a workDir — they must
    // resolve there, not against the engine-host process CWD.
    final a = File('${tmp.path}\\v.mp4')..writeAsBytesSync([1, 2]);
    final b = File('${tmp.path}\\a.m4a')..writeAsBytesSync([3]);
    final r = await muxer.mux(
      const MuxStep(
        inputs: ['v.mp4', 'a.m4a'], // bare names
        outputFileName: 'out.mp4',
      ),
      workDir: tmp.path,
    );
    expect(r.ok, isTrue, reason: '${r.error}');
    final expected = '${tmp.path}\\out.mp4';
    // outputPath must be the real location — the coordinator uses it
    // as a filesystem path directly.
    expect(r.outputPath, expected);
    expect(File(expected).readAsBytesSync(), [1, 2, 3]);
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
  });

  test('mux leaves absolute paths untouched under a workDir',
      () async {
    final a = File('${tmp.path}\\abs.mp4')..writeAsBytesSync([7]);
    final out = '${tmp.path}\\abs_out.mp4';
    final r = await muxer.mux(
      MuxStep(inputs: [a.path], outputFileName: out),
      workDir: tmp.path,
    );
    expect(r.ok, isTrue, reason: '${r.error}');
    expect(r.outputPath, out);
    expect(File(out).readAsBytesSync(), [7]);
  });

  test('empty inputs fail cleanly (no process spawned hang)', () async {
    final r = await muxer.mux(const MuxStep(inputs: [], outputFileName: 'x'));
    expect(r.ok, isFalse);
  });
}
