// Integration-bundle builder (design doc §22): pack a component
// directory into a .fdmbundle (deterministic TAR + manifest) whose
// provenance records the upstream revision and patch queue hashes.
//
//   dart tools/component-build/build_bundle.dart <componentId> <sourceDir> <version> [out.fdmbundle]
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_update_api/freedm_update_api.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        'usage: build_bundle.dart <componentId> <sourceDir> <version> [out]');
    exitCode = 2;
    return;
  }
  final root = File(Platform.script.toFilePath())
      .parent
      .parent
      .parent
      .path;
  final registry = UpstreamRegistry.parse(
      await File('$root/upstream-registry.yaml').readAsString());
  final comp = registry.components[args[0]];
  if (comp == null) {
    stderr.writeln('component ${args[0]} not in registry');
    exitCode = 2;
    return;
  }
  final bytes = await const BundleBuilder().build(
    sourceDir: Directory(args[1]),
    component: comp,
    version: args[2],
    patchDir: root, // patch paths in the registry are repo-relative
  );
  final out = args.length > 3
      ? args[3]
      : '${args[0]}-${args[2]}.fdmbundle';
  await File(out).writeAsBytes(bytes);
  stderr.writeln('wrote $out  sha256=${sha256.convert(bytes)}');
}
