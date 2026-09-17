import 'dart:convert';

import 'registry.dart';

/// What upstream offers right now for one component.
final class UpstreamObservation {
  const UpstreamObservation({
    required this.componentId,
    required this.pinned,
    required this.latest,
    required this.updateAvailable,
    this.repository,
    this.license,
    this.assetUrl,
    this.error,
    this.checkedAt,
  });

  final String componentId;
  final String? pinned;
  final String? latest;
  final bool updateAvailable;
  final String? repository;
  final String? license;
  final String? assetUrl;
  final String? error;
  final DateTime? checkedAt;

  Map<String, Object?> toJson() => {
        'componentId': componentId,
        'pinned': pinned,
        'latest': latest,
        'updateAvailable': updateAvailable,
        'repository': repository,
        'license': license,
        'assetUrl': assetUrl,
        'error': error,
        'checkedAt': checkedAt?.toIso8601String(),
      };
}

/// Audit-evidence report — one run of the upstream watch (§22).
final class WatchReport {
  const WatchReport(this.generatedAt, this.observations);
  final DateTime generatedAt;
  final List<UpstreamObservation> observations;

  String toJson() => const JsonEncoder.withIndent('  ').convert({
        'generatedAt': generatedAt.toIso8601String(),
        'components': [for (final o in observations) o.toJson()],
      });
}

/// Checks each runtime component's upstream for a newer release.
/// HTTP is injected ([fetchJson]) so tests never touch the network —
/// the bin wrapper wires dart:io HttpClient.
final class UpstreamWatch {
  const UpstreamWatch({required this.fetchJson, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// GET a URL → decoded JSON (Map or List).
  final Future<Object?> Function(Uri url) fetchJson;
  final DateTime Function() _clock;

  Future<WatchReport> checkAll(
    UpstreamRegistry registry, {
    Map<String, String> pinned = const {},
  }) async {
    final out = <UpstreamObservation>[];
    for (final c in registry.components.values) {
      if (!c.isRuntime) continue;
      out.add(await _checkOne(c, pinned[c.id]));
    }
    return WatchReport(_clock().toUtc(), out);
  }

  Future<UpstreamObservation> _checkOne(
      RegistryComponent c, String? pinned) async {
    try {
      final repo = _repoPath(c.repository);
      if (repo == null) throw StateError('no repository');
      String? latest;
      String? assetUrl;
      if (c.distributionType == 'github_release_asset' ||
          c.distributionType == 'github_release') {
        final j = await fetchJson(Uri.https(
            'api.github.com', '/repos/$repo/releases/latest')) as Map;
        latest = '${j['tag_name']}';
        final assets = j['assets'];
        if (assets is List && c.assetPattern != null) {
          final re = _glob(c.assetPattern!);
          for (final a in assets) {
            if (a is Map && re.hasMatch('${a['name']}')) {
              assetUrl = '${a['browser_download_url']}';
              break;
            }
          }
        }
      } else {
        // Vendored/github_source: latest default-branch commit.
        final j = await fetchJson(Uri.https(
            'api.github.com', '/repos/$repo/commits',
            {'per_page': '1'}));
        if (j is List && j.isNotEmpty) {
          latest = '${(j.first as Map)['sha']}';
        }
      }
      final changed = latest != null && pinned != null && latest != pinned;
      return UpstreamObservation(
        componentId: c.id,
        pinned: pinned,
        latest: latest,
        updateAvailable: changed,
        repository: c.repository,
        license: c.license,
        assetUrl: assetUrl,
        checkedAt: _clock().toUtc(),
      );
    } catch (e) {
      return UpstreamObservation(
        componentId: c.id,
        pinned: pinned,
        latest: null,
        updateAvailable: false,
        repository: c.repository,
        license: c.license,
        error: '$e',
        checkedAt: _clock().toUtc(),
      );
    }
  }

  /// 'https://github.com/owner/repo' → 'owner/repo'
  String? _repoPath(String? url) {
    if (url == null) return null;
    final u = Uri.parse(url);
    final segs = u.pathSegments;
    if (segs.length < 2) return null;
    return '${segs[0]}/${segs[1]}';
  }

  RegExp _glob(String pattern) => RegExp('^' +
      pattern.splitMapJoin('*',
          onMatch: (_) => '.*',
          onNonMatch: RegExp.escape) +
      '\$');
}
