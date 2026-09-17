import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_update_api/freedm_update_api.dart';
import 'package:test/test.dart';

final class FakeSource implements UpdateSource {
  FakeSource(this.candidates);
  final Map<String, ComponentCandidate> candidates;
  @override
  Future<ComponentCandidate?> latestFor(String id) async =>
      candidates[id];
}

final class FakeFetcher implements BundleFetcher {
  FakeFetcher(this.payloads);
  final Map<String, List<int>> payloads;
  final fetched = <String>[];
  @override
  Future<List<int>> fetch(String url) async {
    fetched.add(url);
    final b = payloads[url];
    if (b == null) throw StateError('404 $url');
    return b;
  }
}

ComponentCandidate cand(String id, String ver, List<int> bytes,
        {String url = 'https://x/bundle'}) =>
    ComponentCandidate(
        componentId: id,
        version: ver,
        bundleUrl: '$url-$ver',
        sha256: sha256.convert(bytes).toString());

void main() {
  group('ComponentManager (memory store)', () {
    final bytesA = utf8.encode('bundle-A');
    final bytesB = utf8.encode('bundle-B');

    test('update installs, verifies hash, activates', () async {
      final store = MemoryBundleStore();
      final c = cand('engine.brisk', '1.1', bytesB);
      final m = ComponentManager(
        source: FakeSource({'engine.brisk': c}),
        fetcher: FakeFetcher({c.bundleUrl: bytesB}),
        store: store,
      );
      final r = await m.update('engine.brisk');
      expect(r.outcome, UpdateOutcome.updated);
      final st = await m.state('engine.brisk');
      expect(st.activeVersion, '1.1');
      expect(st.installed['1.1'], isNotNull);
    });

    test('tampered bundle is discarded, never activated', () async {
      final store = MemoryBundleStore();
      final c = cand('engine.brisk', '9.9', bytesB);
      final m = ComponentManager(
        source: FakeSource({'engine.brisk': c}),
        fetcher: FakeFetcher({c.bundleUrl: utf8.encode('EVIL')}),
        store: store,
      );
      final r = await m.update('engine.brisk');
      expect(r.outcome, UpdateOutcome.verifyFailed);
      expect((await m.state('engine.brisk')).activeVersion, isNull);
    });

    test('pinned component refuses update; pin toggles', () async {
      final store = MemoryBundleStore();
      final c = cand('engine.brisk', '1.1', bytesB);
      final m = ComponentManager(
        source: FakeSource({'engine.brisk': c}),
        fetcher: FakeFetcher({c.bundleUrl: bytesB}),
        store: store,
      );
      await m.setPinned('engine.brisk', true);
      final r = await m.update('engine.brisk');
      expect(r.outcome, UpdateOutcome.pinned);
      await m.setPinned('engine.brisk', false);
      expect((await m.update('engine.brisk')).outcome,
          UpdateOutcome.updated);
    });

    test('rollback flips active marker; gc keeps active+referenced',
        () async {
      final store = MemoryBundleStore();
      final cA = cand('e', '1.0', bytesA, url: 'https://x/a');
      final cB = cand('e', '2.0', bytesB, url: 'https://x/b');
      final src = FakeSource({'e': cA});
      final m = ComponentManager(
        source: src,
        fetcher: FakeFetcher(
            {cA.bundleUrl: bytesA, cB.bundleUrl: bytesB}),
        store: store,
      );
      await m.update('e');
      src.candidates['e'] = cB;
      await m.update('e');
      expect((await m.state('e')).activeVersion, '2.0');

      // Task binds to 1.0 → gc must keep it.
      await m.acquireRef('e', '1.0');
      expect(await m.rollback('e', '1.0'), isTrue);
      expect((await m.state('e')).activeVersion, '1.0');

      // Re-activate 2.0, keep the ref on 1.0 → gc removes nothing.
      await m.rollback('e', '2.0');
      expect(await m.gc('e'), isEmpty);
      await m.releaseRef('e', '1.0');
      expect(await m.gc('e'), ['1.0']);
      expect(store.deleted, ['e@1.0']);
    });
  });

  group('LocalBundleStore (disk)', () {
    test('install + activate persist state across reload', () async {
      final dir = await Directory.systemTemp.createTemp('freedm-upd');
      addTearDown(() => dir.delete(recursive: true));
      final store = LocalBundleStore(dir.path);
      final ff = utf8.encode('ff');
      final c = cand('media.ffmpeg', '7.1', ff);
      final m2 = ComponentManager(
        source: FakeSource({}),
        fetcher: FakeFetcher({c.bundleUrl: ff}),
        store: store,
      );
      final r = await m2.installCandidate('media.ffmpeg', c);
      expect(r.outcome, UpdateOutcome.updated);
      final reloaded = await LocalBundleStore(dir.path)
          .load('media.ffmpeg');
      expect(reloaded.activeVersion, '7.1');
      expect(File('${reloaded.installed['7.1']!.path}'
              '${Platform.pathSeparator}bundle.bin')
          .existsSync(), isTrue);
    });
  });
}
