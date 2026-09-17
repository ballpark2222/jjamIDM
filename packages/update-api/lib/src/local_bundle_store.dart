import 'dart:convert';
import 'dart:io';

import 'component_manager.dart';
import 'update_ports.dart';
import 'update_types.dart';

/// Filesystem [BundleStore]:
///   <root>/<componentId>/
///     state.json            — ComponentState (atomic rename write)
///     <version>/bundle.bin  — staged bundle payload
/// Activation flips `state.json`'s activeVersion via temp+rename —
/// no symlinks (Windows requires privilege for those).
final class LocalBundleStore implements BundleStore {
  LocalBundleStore(this.root);
  final String root;

  String _dirFor(String id) => '$root${Platform.pathSeparator}$id';
  String _statePath(String id) =>
      '${_dirFor(id)}${Platform.pathSeparator}state.json';
  String _versionDir(String id, String v) =>
      '${_dirFor(id)}${Platform.pathSeparator}$v';

  @override
  Future<String> install(
      String id, String version, List<int> bytes) async {
    final dir = _versionDir(id, version);
    await Directory(dir).create(recursive: true);
    final f = File('$dir${Platform.pathSeparator}bundle.bin');
    await f.writeAsBytes(bytes, flush: true);
    return dir;
  }

  /// Atomic repoint: write state.json.tmp then rename over the old
  /// file (delete first — Windows rename won't clobber).
  @override
  Future<void> activate(String id, String version) async {
    final state = await load(id);
    await save(state.copyWith(activeVersion: version));
  }

  @override
  Future<void> delete(String id, String version) async {
    final dir = Directory(_versionDir(id, version));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<ComponentState> load(String id) async {
    final f = File(_statePath(id));
    if (!f.existsSync()) return ComponentState(componentId: id);
    return decodeState(await f.readAsString());
  }

  @override
  Future<void> save(ComponentState state) async {
    await Directory(_dirFor(state.componentId))
        .create(recursive: true);
    final target = File(_statePath(state.componentId));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(encodeState(state), flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // Windows: rename fails if the target exists.
      if (target.existsSync()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  /// Convenience used by tools/tests.
  static String encode(ComponentState s) => encodeState(s);
}
