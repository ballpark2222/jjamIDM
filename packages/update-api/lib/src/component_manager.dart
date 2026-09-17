import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'update_ports.dart';
import 'update_types.dart';

/// Dev-stage verifier: sha256 of the bundle must equal the candidate
/// hash; a signature, if present, is verified by the real impl in
/// release builds. Never accepts an empty/mismatched hash.
final class Sha256OnlyVerifier implements SignatureVerifier {
  const Sha256OnlyVerifier();

  @override
  Future<bool> verify(
      List<int> bundleBytes, ComponentCandidate candidate) async {
    if (candidate.sha256.isEmpty) return false;
    return sha256.convert(bundleBytes).toString() ==
        candidate.sha256.toLowerCase();
  }
}

/// One-click component lifecycle (design doc §21):
///   check → fetch → verify → install → atomic activate → GC.
/// Rollback flips the active marker back to a still-installed
/// version. Engine affinity: [acquireRef]/[releaseRef] pin a bundle
/// while tasks use it; GC never deletes referenced or active dirs.
final class ComponentManager {
  ComponentManager({
    required UpdateSource source,
    required BundleFetcher fetcher,
    required BundleStore store,
    SignatureVerifier verifier = const Sha256OnlyVerifier(),
  })  : _source = source,
        _fetcher = fetcher,
        _store = store,
        _verifier = verifier;

  final UpdateSource _source;
  final BundleFetcher _fetcher;
  final BundleStore _store;
  final SignatureVerifier _verifier;

  Future<ComponentState> state(String componentId) =>
      _store.load(componentId);

  Future<ComponentCandidate?> checkForUpdate(String componentId) =>
      _source.latestFor(componentId);

  /// Full one-click update. Refuses to touch pinned components and
  /// never activates an unverified bundle.
  Future<UpdateResult> update(String componentId) async {
    final state = await _store.load(componentId);
    if (state.pinned) {
      return const UpdateResult(UpdateOutcome.pinned,
          detail: 'component is version-pinned');
    }
    ComponentCandidate? cand;
    try {
      cand = await _source.latestFor(componentId);
    } catch (e) {
      return UpdateResult(UpdateOutcome.fetchFailed,
          detail: 'update check failed: $e');
    }
    if (cand == null) {
      return const UpdateResult(UpdateOutcome.alreadyCurrent);
    }
    if (state.activeVersion == cand.version) {
      return UpdateResult(UpdateOutcome.alreadyCurrent,
          version: cand.version);
    }
    return _installAndActivate(componentId, cand);
  }

  /// Install a specific candidate (pinned-version flow — the caller
  /// chose the version, so `pinned` does not block it).
  Future<UpdateResult> installCandidate(
      String componentId, ComponentCandidate cand) async {
    return _installAndActivate(componentId, cand);
  }

  Future<UpdateResult> _installAndActivate(
      String componentId, ComponentCandidate cand) async {
    List<int> bytes;
    try {
      bytes = await _fetcher.fetch(cand.bundleUrl);
    } catch (e) {
      return UpdateResult(UpdateOutcome.fetchFailed, detail: '$e');
    }
    if (!await _verifier.verify(bytes, cand)) {
      return UpdateResult(UpdateOutcome.verifyFailed,
          version: cand.version,
          detail: 'hash/signature mismatch — bundle discarded');
    }
    final state = await _store.load(componentId);
    final path =
        await _store.install(componentId, cand.version, bytes);
    final installed = Map.of(state.installed)
      ..[cand.version] = InstalledComponent(
        componentId: componentId,
        version: cand.version,
        path: path,
        installedAt: DateTime.now().toUtc(),
      );
    var next = state.copyWith(installed: installed);
    await _store.save(next);
    await _store.activate(componentId, cand.version);
    next = next.copyWith(activeVersion: cand.version);
    await _store.save(next);
    return UpdateResult(UpdateOutcome.updated, version: cand.version);
  }

  /// Flip the active marker to an already-installed version.
  Future<bool> rollback(String componentId, String toVersion) async {
    final state = await _store.load(componentId);
    final target = state.installed[toVersion];
    if (target == null || state.activeVersion == toVersion) {
      return false;
    }
    await _store.activate(componentId, toVersion);
    await _store.save(state.copyWith(activeVersion: toVersion));
    return true;
  }

  Future<void> setPinned(String componentId, bool pinned) async {
    final state = await _store.load(componentId);
    await _store.save(state.copyWith(pinned: pinned));
  }

  /// Engine affinity: a task bound to a bundle version holds a ref
  /// until it completes; GC skips referenced versions.
  Future<void> acquireRef(String componentId, String version) =>
      _bumpRef(componentId, version, 1);

  Future<void> releaseRef(String componentId, String version) =>
      _bumpRef(componentId, version, -1);

  Future<void> _bumpRef(
      String componentId, String version, int delta) async {
    final state = await _store.load(componentId);
    final inst = state.installed[version];
    if (inst == null) return;
    final refs = inst.activeTaskRefs + delta;
    final installed = Map.of(state.installed)
      ..[version] = inst.copyWith(activeTaskRefs: refs < 0 ? 0 : refs);
    await _store.save(state.copyWith(installed: installed));
  }

  /// Delete versions that are neither active nor referenced.
  /// Returns the versions removed.
  Future<List<String>> gc(String componentId) async {
    final state = await _store.load(componentId);
    final removed = <String>[];
    final kept = Map.of(state.installed);
    for (final e in state.installed.entries) {
      if (e.key == state.activeVersion) continue;
      if (e.value.activeTaskRefs > 0) continue;
      await _store.delete(componentId, e.key);
      kept.remove(e.key);
      removed.add(e.key);
    }
    if (removed.isNotEmpty) {
      await _store.save(state.copyWith(installed: kept));
    }
    return removed;
  }
}

/// In-memory [BundleStore] for tests and the dev shell.
final class MemoryBundleStore implements BundleStore {
  final states = <String, ComponentState>{};
  final deleted = <String>[];

  @override
  Future<String> install(String componentId, String version,
      List<int> bundleBytes) async =>
      'mem://$componentId/$version';

  @override
  Future<void> activate(String componentId, String version) async {}

  @override
  Future<void> delete(String componentId, String version) async {
    deleted.add('$componentId@$version');
  }

  @override
  Future<ComponentState> load(String componentId) async =>
      states[componentId] ??
      ComponentState(componentId: componentId);

  @override
  Future<void> save(ComponentState state) async {
    states[state.componentId] = state;
  }
}

/// JSON persistence shape shared by disk-backed stores.
Map<String, Object?> stateToJson(ComponentState s) => {
      'componentId': s.componentId,
      'activeVersion': s.activeVersion,
      'pinned': s.pinned,
      'installed': {
        for (final e in s.installed.entries)
          e.key: {
            'path': e.value.path,
            'installedAt': e.value.installedAt.toIso8601String(),
            'activeTaskRefs': e.value.activeTaskRefs,
          },
      },
    };

ComponentState stateFromJson(Map<String, Object?> j) {
  final installed = <String, InstalledComponent>{};
  final raw = j['installed'];
  if (raw is Map) {
    raw.forEach((k, v) {
      if (v is Map) {
        installed['$k'] = InstalledComponent(
          componentId: '${j['componentId']}',
          version: '$k',
          path: '${v['path']}',
          installedAt: DateTime.tryParse('${v['installedAt']}') ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          activeTaskRefs:
              (v['activeTaskRefs'] as num?)?.toInt() ?? 0,
        );
      }
    });
  }
  return ComponentState(
    componentId: '${j['componentId']}',
    activeVersion: j['activeVersion'] as String?,
    pinned: j['pinned'] == true,
    installed: installed,
  );
}

/// Encode/decode helpers for disk stores.
String encodeState(ComponentState s) =>
    const JsonEncoder.withIndent('  ').convert(stateToJson(s));

ComponentState decodeState(String text) =>
    stateFromJson(jsonDecode(text) as Map<String, Object?>);
