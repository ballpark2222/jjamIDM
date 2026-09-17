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

  test('empty inputs fail cleanly (no process spawned hang)', () async {
    final r = await muxer.mux(const MuxStep(inputs: [], outputFileName: 'x'));
    expect(r.ok, isFalse);
  });
}
