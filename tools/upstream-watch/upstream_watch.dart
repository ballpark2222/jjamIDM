// Upstream watch (design doc §22): check each runtime component's
// upstream for a newer release and write an audit report.
//
//   dart tools/upstream-watch/upstream_watch.dart [--out report.json]
import 'dart:convert';
import 'dart:io';

import 'package:freedm_update_api/freedm_update_api.dart';

Future<void> main(List<String> args) async {
  final root = File(Platform.script.toFilePath())
      .parent
      .parent
      .parent
      .path;
  final registry = UpstreamRegistry.parse(
      await File('$root/upstream-registry.yaml').readAsString());

  // Pinned versions from components.lock (minimal TOML scan —
  // the lock file is small and hand-editable).
  final lock = await File('$root/components.lock').readAsString();
  final pinned = <String, String>{};
  String? section;
  for (final line in lock.split('\n')) {
    final s = line.trim();
    final m = RegExp(r'^\[(.+)\]').firstMatch(s);
    if (m != null) {
      section = m.group(1);
      continue;
    }
    final kv = RegExp(r'^(upstream_revision|version)\s*=\s*"(.+)"')
        .firstMatch(s);
    if (kv != null && section != null) {
      final id = registry.components.keys.firstWhere(
          (k) => k.replaceAll('.', '_') == section || k == section,
          orElse: () => section!);
      pinned[id] = kv.group(2)!;
    }
  }

  final client = HttpClient();
  final watch = UpstreamWatch(fetchJson: (u) async {
    final req = await client.getUrl(u);
    req.headers.set('User-Agent', 'freedm-upstream-watch');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    if (res.statusCode != 200) {
      throw StateError('${res.statusCode} for $u');
    }
    return jsonDecode(await utf8.decodeStream(res));
  });

  final report = await watch.checkAll(registry, pinned: pinned);
  client.close();

  final out = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : '$root/docs/upstream-report.json';
  await File(out).writeAsString(report.toJson());
  for (final o in report.observations) {
    final flag = o.updateAvailable ? 'UPDATE ' : 'ok     ';
    stderr.writeln(
        '$flag${o.componentId}  pinned=${o.pinned} latest=${o.latest}${o.error != null ? '  (${o.error})' : ''}');
  }
  stderr.writeln('report -> $out');
}
