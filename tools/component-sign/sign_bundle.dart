/// Sign a .fdmbundle with the project Ed25519 key (fdmsig/1).
///
///   dart run tools/component-sign/sign_bundle.dart genkey KEYFILE
///   dart run tools/component-sign/sign_bundle.dart pubkey KEYFILE
///   dart run tools/component-sign/sign_bundle.dart sign KEYFILE BUNDLE
///
/// Keyfile format: hex 32-byte seed. Signatures are written to
/// `bundle.sig` as base64 — attach to ComponentCandidate.signature.
library;

import 'dart:io';

import 'package:freedm_update_api/freedm_update_api.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: sign_bundle.dart genkey|pubkey|sign ...');
    exit(64);
  }
  switch (args[0]) {
    case 'genkey':
      final s = await Ed25519Signer.generate();
      final pub = await s.publicKeyBytes();
      File(args[1]).writeAsStringSync(
          _hex(await s.keyPair.extractPrivateKeyBytes()));
      stdout.writeln('wrote ${args[1]}');
      stdout.writeln('public key (hex): ${_hex(pub)}');
    case 'pubkey':
      final s = await _load(args[1]);
      stdout.writeln(_hex(await s.publicKeyBytes()));
    case 'sign':
      final s = await _load(args[1]);
      final bytes = File(args[2]).readAsBytesSync();
      final sig = await s.sign(bytes);
      File('${args[2]}.sig').writeAsStringSync('$sig\n');
      stdout.writeln('signature -> ${args[2]}.sig');
      stdout.writeln(sig);
    default:
      stderr.writeln('unknown command ${args[0]}');
      exit(64);
  }
}

Future<Ed25519Signer> _load(String keyfile) {
  final hex = File(keyfile).readAsStringSync().trim();
  final seed = List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
  return Ed25519Signer.fromSeed(seed);
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
