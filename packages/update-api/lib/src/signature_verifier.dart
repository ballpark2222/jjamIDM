import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'component_manager.dart';
import 'update_ports.dart';
import 'update_types.dart';

/// Ed25519 bundle signature verification (design doc §21 release
/// path). The signing key is pinned — a bundle is only installable
/// when it carries a valid detached signature made by that key.
///
/// Wire format (fdmsig/1):
///   candidate.signature = base64(64-byte ed25519 signature)
///   signed payload      = raw bundle bytes (the .fdmbundle)
final class Ed25519SignatureVerifier implements SignatureVerifier {
  const Ed25519SignatureVerifier({required this.trustedPublicKey});

  /// The project signing key (32 bytes). Pinned at build time —
  /// rotating it is a release decision, not a network fetch.
  final List<int> trustedPublicKey;

  static final _algo = Ed25519();

  /// The hash gate stays on regardless — signature is in addition
  /// to sha256, not instead of it.
  @override
  Future<bool> verify(
      List<int> bundleBytes, ComponentCandidate candidate) async {
    if (!await const Sha256OnlyVerifier()
        .verify(bundleBytes, candidate)) {
      return false;
    }
    final sig64 = candidate.signature;
    if (sig64 == null) return false;
    final List<int> sig;
    try {
      sig = base64Decode(sig64.replaceAll(RegExp(r'\s+'), ''));
    } catch (_) {
      return false;
    }
    if (sig.length != 64) return false;
    return _algo.verify(
      bundleBytes,
      signature: Signature(sig,
          publicKey: SimplePublicKey(trustedPublicKey,
              type: KeyPairType.ed25519)),
    );
  }
}

/// Dev convenience — key generation + signing for the bundle
/// pipeline (tools/component-sign).
final class Ed25519Signer {
  const Ed25519Signer(this.keyPair);
  final SimpleKeyPair keyPair;

  static Future<Ed25519Signer> generate() async =>
      Ed25519Signer(await Ed25519().newKeyPair());

  static Future<Ed25519Signer> fromSeed(List<int> seed) async =>
      Ed25519Signer(await Ed25519().newKeyPairFromSeed(seed));

  Future<List<int>> publicKeyBytes() async =>
      (await keyPair.extractPublicKey()).bytes;

  Future<String> sign(List<int> bundleBytes) async {
    final sig = await Ed25519().sign(bundleBytes, keyPair: keyPair);
    return base64Encode(sig.bytes);
  }
}
