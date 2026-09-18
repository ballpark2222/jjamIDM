import 'dart:async';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_engine_host/engine_client.dart';
import 'package:freedm_test_server/freedm_test_server.dart';
import 'package:test/test.dart';

/// E2E: protocol v2 media.* — real yt-dlp/ffmpeg against the local
/// HLS fixture. Skips when the binaries are absent (CI may not ship
/// them); the real-binary evidence lives in this repo's run log.
void main() {
  late FixtureServer fixture;
  late Directory outDir;
  late Directory dataDir;
  EngineHostClient? client;

  String? tool(String name) {
    var d = Directory.current.absolute;
    for (var i = 0; i < 8; i++) {
      for (final cand in [
        '${d.parent.path}/.tools/$name',
        '${d.parent.path}/.tools/ffmpeg-extract/'
            'ffmpeg-9.0.1-essentials_build/bin/$name',
      ]) {
        if (File(cand).existsSync()) return cand;
      }
      d = d.parent;
    }
    return null;
  }

  final ytdlp = tool('yt-dlp.exe');
  final ffmpeg = tool('ffmpeg.exe');

  setUpAll(() async {
    fixture = await FixtureServer.start();
    if (ytdlp == null || ffmpeg == null) return;
    dataDir = await Directory.systemTemp.createTemp('ehc-media');
    var dir = Directory.current;
    String? hostMain;
    final sep = Platform.pathSeparator;
    for (var i = 0; i < 8; i++) {
      final f = File(
          '${dir.path}${sep}apps${sep}engine-host${sep}bin${sep}main.dart');
      if (f.existsSync()) {
        hostMain = f.path;
        break;
      }
      final local = File('${dir.path}${sep}bin${sep}main.dart');
      if (local.existsSync() &&
          File('${dir.path}${sep}pubspec.yaml')
              .readAsStringSync()
              .contains('freedm_engine_host')) {
        hostMain = local.path;
        break;
      }
      dir = dir.parent;
    }
    outDir = await Directory.systemTemp.createTemp('ehc-media-out');
    client = await EngineHostClient.spawn([
      Platform.resolvedExecutable,
      hostMain!,
      '--temp-root', '${dataDir.path}${sep}tmp',
      '--data-dir', dataDir.path,
      '--ytdlp', ytdlp,
      '--ffmpeg', ffmpeg,
    ]);
  });
  tearDownAll(() async {
    await client?.shutdown();
    await fixture.close();
  });

  test('media.probe + media.enqueue → completed mkv', () async {
    if (client == null) {
      return; // binaries absent — skip (documented)
    }
    expect(client!.supportsMedia, isTrue);

    final probe = await client!
        .probeMedia('${fixture.base}/hls/master.m3u8');
    expect(probe, isNotNull);
    expect(probe!['supported'], isTrue);
    // The quality picker rides on these fields — the wire shape
    // must keep carrying them for the dialog to render.
    expect(probe['formats'], isA<List>());
    expect(probe.containsKey('subtitles'), isTrue);

    // Picker flow: probe → choose a real formatId → enqueue with it.
    // Prefer a video format like the dialog does; an empty list
    // just means "best" — both are legal paths.
    final formats = probe['formats'] as List;
    final pick = formats.whereType<Map>().firstWhere(
        (f) => f['hasVideo'] == true,
        orElse: () => const <String, Object?>{});
    final sel = pick['formatId'] as String?;

    final done = Completer<DownloadTask>();
    final sub = client!.mediaTasks.listen((t) {
      if (t.status == DownloadStatus.completed &&
          !done.isCompleted) {
        done.complete(t);
      }
      if (t.status == DownloadStatus.failed && !done.isCompleted) {
        done.completeError(StateError('media task failed: '
            '${t.lastError}'));
      }
    });

    final id = await client!.enqueueMedia(
      pageUrl: '${fixture.base}/hls/master.m3u8',
      targetDirectory: outDir.path,
      videoFormatId: sel,
    );
    expect(id.value, isNotEmpty);

    final t = await done.future.timeout(const Duration(minutes: 3));
    expect(t.status, DownloadStatus.completed);
    // The delivered artifact must carry a real container ext —
    // component yt-dlp downloads used to land extensionless.
    expect(
        outDir.listSync().whereType<File>().any(
            (f) => f.lengthSync() > 0),
        isTrue);
    final delivered = t.metadata['outputPath'];
    expect(delivered, isNotNull);
    expect(delivered,
        matches(RegExp(r'\.(mp4|mkv|webm|ts|m4a|mov|avi)$')));
    expect(File(delivered!).existsSync(), isTrue);
    await sub.cancel();

    // media.list snapshot — a client that missed the broadcast
    // still sees the task's terminal record.
    final listed = await client!.listMediaTasks();
    expect(listed.map((e) => e.id), contains(id));
    expect(
        listed.singleWhere((e) => e.id == id).kind,
        TaskKind.media);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
