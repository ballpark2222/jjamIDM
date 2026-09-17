import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'registry.dart';

/// `.fdmbundle` container (design doc §22): a JSON document carrying
/// a base64 TAR payload plus a manifest of every file's sha256.
///
/// Layout:
///   {
///     "format": "fdmbundle/1",
///     "componentId": ...,
///     "version": ...,
///     "builtAt": ...,
///     "provenance": {repository, revision, license, patches[]},
///     "files": [{path, size, sha256}],   // sorted — reproducible
///     "payloadBase64": "<tar>"
///   }
///
/// TAR is used (not zip) because it needs no external dependency and
/// is deterministic when written with sorted entries + fixed mtimes.
final class BundleBuilder {
  const BundleBuilder({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Pack [sourceDir] into fdmbundle bytes. [component] provides
  /// provenance; patch existence is verified and patch hashes are
  /// recorded in the manifest.
  Future<List<int>> build({
    required Directory sourceDir,
    required RegistryComponent component,
    required String version,
    String? patchDir,
  }) async {
    final entries = <_Entry>[];
    await for (final f in sourceDir.list(recursive: true)) {
      if (f is! File) continue;
      final rel = f.path
          .substring(sourceDir.path.length)
          .replaceAll('\\', '/')
          .replaceAll(RegExp('^/+'), '');
      final bytes = await f.readAsBytes();
      entries.add(_Entry(rel, bytes));
    }
    entries.sort((a, b) => a.path.compareTo(b.path));

    final patchProof = <Map<String, Object?>>[];
    if (patchDir != null) {
      for (final p in component.patches) {
        // Patch paths in the registry are repo-relative.
        final f = File(
            '$patchDir${Platform.pathSeparator}${p.replaceAll('/', Platform.pathSeparator)}');
        if (!f.existsSync()) {
          throw StateError('patch missing from queue: $p');
        }
        patchProof.add({
          'patch': p,
          'sha256': sha256.convert(await f.readAsBytes()).toString(),
        });
      }
    }

    final manifest = {
      'format': 'fdmbundle/1',
      'componentId': component.id,
      'version': version,
      'builtAt': _clock().toUtc().toIso8601String(),
      'provenance': {
        'repository': component.repository,
        'revision': component.revision,
        'license': component.license,
        'patches': patchProof,
      },
      'files': [
        for (final e in entries)
          {
            'path': e.path,
            'size': e.bytes.length,
            'sha256': sha256.convert(e.bytes).toString(),
          },
      ],
      'payloadBase64': base64Encode(_tar(entries)),
    };
    return utf8.encode(const JsonEncoder.withIndent('  ')
        .convert(manifest));
  }

  /// Verify a bundle: payload files match the manifest hashes.
  /// Returns the extracted entries on success.
  static List<({String path, List<int> bytes})> unpack(
      List<int> bundleBytes) {
    final doc =
        jsonDecode(utf8.decode(bundleBytes)) as Map<String, Object?>;
    if (doc['format'] != 'fdmbundle/1') {
      throw FormatException('not an fdmbundle/1 document');
    }
    final payload = base64Decode('${doc['payloadBase64']}');
    final files = untar(payload);
    final declared = {
      for (final f in (doc['files'] as List))
        '${(f as Map)['path']}': '${f['sha256']}',
    };
    for (final f in files) {
      final want = declared[f.path];
      if (want == null ||
          sha256.convert(f.bytes).toString() != want) {
        throw FormatException(
            'bundle payload hash mismatch: ${f.path}');
      }
    }
    return files;
  }

  // ---- minimal deterministic TAR (ustar, mtime 0) ----

  List<int> _tar(List<_Entry> entries) {
    final out = BytesBuilder();
    for (final e in entries) {
      final name = utf8.encode(e.path);
      if (name.length > 100) {
        throw StateError('tar name too long: ${e.path}');
      }
      final header = List<int>.filled(512, 0);
      header.setRange(0, name.length, name);
      _octal(header, 100, 8, 420); // mode 0644 (no octal literals in Dart)
      _octal(header, 108, 8, 0); // uid
      _octal(header, 116, 8, 0); // gid
      _octal(header, 124, 12, e.bytes.length); // size
      _octal(header, 136, 12, 0); // mtime — deterministic
      header.setRange(257, 262, utf8.encode('ustar'));
      header[156] = 48; // typeflag '0'
      // checksum: spaces then sum
      header.setRange(148, 156, utf8.encode('        '));
      var sum = 0;
      for (final b in header) {
        sum += b;
      }
      _octal(header, 148, 7, sum);
      header[155] = 32;
      out.add(header);
      out.add(e.bytes);
      final pad = (512 - e.bytes.length % 512) % 512;
      out.add(List<int>.filled(pad, 0));
    }
    out.add(List<int>.filled(1024, 0)); // end blocks
    return out.toBytes();
  }

  void _octal(List<int> h, int off, int len, int value) {
    final s = value.toRadixString(8).padLeft(len - 1, '0');
    h.setRange(off, off + len - 1, utf8.encode(s));
  }

  /// Decode a TAR produced by [_tar] (also tolerates regular ustar).
  static List<({String path, List<int> bytes})> untar(
      List<int> tar) {
    final out = <({String path, List<int> bytes})>[];
    var off = 0;
    while (off + 512 <= tar.length) {
      final header = tar.sublist(off, off + 512);
      if (header.every((b) => b == 0)) break;
      final name = utf8.decode(header.sublist(0, 100))
          .split('\x00')
          .first;
      final sizeOct = utf8
          .decode(header.sublist(124, 136))
          .split('\x00')
          .first
          .trim();
      final size =
          sizeOct.isEmpty ? 0 : int.parse(sizeOct, radix: 8);
      off += 512;
      out.add((path: name, bytes: tar.sublist(off, off + size)));
      off += size + ((512 - size % 512) % 512);
    }
    return out;
  }
}

final class _Entry {
  _Entry(this.path, this.bytes);
  final String path;
  final List<int> bytes;
}
