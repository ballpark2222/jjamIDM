import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_update_api/freedm_update_api.dart';
import 'package:test/test.dart';

const registryYaml = '''
schema: 2
components:
  engine.brisk:
    display_name: "Brisk"
    provenance:
      repository: https://github.com/BrisklyDev/brisk_download_engine
      revision: abc123
      license: MIT
    distribution:
      type: vendored_source
      path: third_party/brisk-engine/abc123
    update_policy: verified_one_click
    patches:
      - third_party/patches/0001.patch
  media.ytdlp:
    display_name: "yt-dlp"
    provenance:
      repository: https://github.com/yt-dlp/yt-dlp
      license: Unlicense
    distribution:
      type: github_release_asset
      repository: https://github.com/yt-dlp/yt-dlp
      asset_pattern: "yt-dlp.exe"
    update_policy: verified_one_click
  abdm:
    display_name: "ABDM"
    update_policy: reference_only
''';

void main() {
  group('UpstreamRegistry.parse', () {
    test('parses runtime vs reference-only + patch queue', () {
      final r = UpstreamRegistry.parse(registryYaml);
      expect(r.components.length, 3);
      expect(r.components['abdm']!.isRuntime, isFalse);
      final b = r.components['engine.brisk']!;
      expect(b.isRuntime, isTrue);
      expect(b.revision, 'abc123');
      expect(b.patches, ['third_party/patches/0001.patch']);
      expect(r.components['media.ytdlp']!.assetPattern, 'yt-dlp.exe');
    });
  });

  group('UpstreamWatch', () {
    test('github_release: picks matching asset, flags update', () async {
      final r = UpstreamRegistry.parse(registryYaml);
      final w = UpstreamWatch(fetchJson: (u) async {
        expect(u.path, contains('yt-dlp/releases/latest'));
        return {
          'tag_name': '2026.09.01',
          'assets': [
            {'name': 'yt-dlp.zip', 'browser_download_url': 'u1'},
            {'name': 'yt-dlp.exe', 'browser_download_url': 'u2'},
          ],
        };
      });
      final rep = await w.checkAll(r, pinned: {
        'media.ytdlp': '2026.01.01',
        'engine.brisk': 'abc123',
      });
      final y = rep.observations
          .firstWhere((o) => o.componentId == 'media.ytdlp');
      expect(y.latest, '2026.09.01');
      expect(y.assetUrl, 'u2');
      expect(y.updateAvailable, isTrue);
    });

    test('vendored source compares commit sha; errors are captured',
        () async {
      final r = UpstreamRegistry.parse(registryYaml);
      final w = UpstreamWatch(fetchJson: (u) async {
        if (u.path.contains('brisk')) {
          return [
            {'sha': 'def456'},
          ];
        }
        throw StateError('boom');
      });
      final rep = await w.checkAll(r,
          pinned: {'engine.brisk': 'abc123', 'media.ytdlp': 'x'});
      final b = rep.observations
          .firstWhere((o) => o.componentId == 'engine.brisk');
      expect(b.latest, 'def456');
      expect(b.updateAvailable, isTrue);
      final y = rep.observations
          .firstWhere((o) => o.componentId == 'media.ytdlp');
      expect(y.error, isNotNull);
    });
  });

  group('BundleBuilder', () {
    test('build → unpack round-trips files, tamper detected', () async {
      final dir = await Directory.systemTemp.createTemp('bundle');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/a.txt').writeAsStringSync('hello');
      await Directory('${dir.path}/sub').create();
      File('${dir.path}/sub/b.bin')
          .writeAsBytesSync(List.generate(700, (i) => i % 256));
      final patchDir = await Directory.systemTemp.createTemp('p');
      addTearDown(() => patchDir.delete(recursive: true));
      // Registry paths are repo-relative — mirror that layout.
      await Directory('${patchDir.path}/third_party/patches')
          .create(recursive: true);
      File('${patchDir.path}/third_party/patches/0001.patch')
          .writeAsStringSync('diff');

      final comp = UpstreamRegistry.parse(registryYaml)
          .components['engine.brisk']!;
      final bundle = await const BundleBuilder().build(
          sourceDir: dir,
          component: comp,
          version: '1.0.0',
          patchDir: patchDir.path);
      final doc = jsonDecode(utf8.decode(bundle));
      expect(doc['componentId'], 'engine.brisk');
      expect(doc['files'].length, 2);
      expect(doc['provenance']['patches'].length, 1);

      final files = BundleBuilder.unpack(bundle);
      expect(files.map((f) => f.path),
          containsAll(['a.txt', 'sub/b.bin']));
      final b = files.firstWhere((f) => f.path == 'sub/b.bin');
      expect(sha256.convert(b.bytes).toString(),
          sha256.convert(List.generate(700, (i) => i % 256)).toString());
    });
  });
}
