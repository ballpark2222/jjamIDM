import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:freedm_update_api/freedm_update_api.dart';
import 'package:test/test.dart';

void main() {
  final bundle = utf8.encode('bundle-payload');

  ComponentCandidate cand({String? sig, List<int>? bytes}) =>
      ComponentCandidate(
          componentId: 'e',
          version: '1',
          bundleUrl: 'u',
          sha256: sha256.convert(bytes ?? bundle).toString(),
          signature: sig);

  test('valid signature verifies; wrong key fails', () async {
    final signer = await Ed25519Signer.generate();
    final pub = await signer.publicKeyBytes();
    final v = Ed25519SignatureVerifier(trustedPublicKey: pub);
    final sig = await signer.sign(bundle);
    expect(await v.verify(bundle, cand(sig: sig)), isTrue);

    final other = await Ed25519Signer.generate();
    final wrongKey = Ed25519SignatureVerifier(
        trustedPublicKey: await other.publicKeyBytes());
    expect(await wrongKey.verify(bundle, cand(sig: sig)), isFalse);
  });

  test('tampered payload fails even with valid signature', () async {
    final signer = await Ed25519Signer.generate();
    final v = Ed25519SignatureVerifier(
        trustedPublicKey: await signer.publicKeyBytes());
    final sig = await signer.sign(bundle);
    expect(await v.verify(utf8.encode('EVIL'), cand(sig: sig)),
        isFalse);
  });

  test('missing/bad signature and hash mismatch rejected', () async {
    final signer = await Ed25519Signer.generate();
    final v = Ed25519SignatureVerifier(
        trustedPublicKey: await signer.publicKeyBytes());
    expect(await v.verify(bundle, cand()), isFalse);
    expect(await v.verify(bundle, cand(sig: '!!!notb64')), isFalse);
    expect(await v.verify(bundle, cand(sig: await signer.sign(bundle),
        bytes: utf8.encode('other'))), isFalse); // sha mismatch
  });

  test('end-to-end: sign → manager install with sig verifier',
      () async {
    final signer = await Ed25519Signer.generate();
    final pub = await signer.publicKeyBytes();
    final c = ComponentCandidate(
      componentId: 'media.ytdlp',
      version: '2026.08.19',
      bundleUrl: 'https://x/ytdlp.bundle',
      sha256: sha256.convert(bundle).toString(),
      signature: await signer.sign(bundle),
    );
    final store = MemoryBundleStore();
    final m = ComponentManager(
      source: _S(c),
      fetcher: _F(bundle),
      store: store,
      verifier: Ed25519SignatureVerifier(trustedPublicKey: pub),
    );
    final r = await m.update('media.ytdlp');
    expect(r.outcome, UpdateOutcome.updated);
    expect((await m.state('media.ytdlp')).activeVersion, '2026.08.19');
  });
}

final class _S implements UpdateSource {
  _S(this.c);
  final ComponentCandidate c;
  @override
  Future<ComponentCandidate?> latestFor(String id) async => c;
}

final class _F implements BundleFetcher {
  _F(this.bytes);
  final List<int> bytes;
  @override
  Future<List<int>> fetch(String url) async => bytes;
}
