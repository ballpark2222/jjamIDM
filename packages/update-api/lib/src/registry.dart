import 'package:yaml/yaml.dart';

/// One component entry from upstream-registry.yaml (design doc §22).
final class RegistryComponent {
  const RegistryComponent({
    required this.id,
    required this.displayName,
    required this.updatePolicy,
    this.repository,
    this.revision,
    this.license,
    this.distributionType,
    this.assetPattern,
    this.patches = const [],
    this.updateClass,
  });

  final String id;
  final String displayName;
  final String updatePolicy; // verified_one_click | reference_only
  final String? repository;
  final String? revision;
  final String? license;
  final String? distributionType;
  final String? assetPattern;
  final List<String> patches;
  final String? updateClass;

  bool get isRuntime => updatePolicy != 'reference_only';
}

/// Parsed upstream-registry.yaml.
final class UpstreamRegistry {
  const UpstreamRegistry(this.components);
  final Map<String, RegistryComponent> components;

  static UpstreamRegistry parse(String yamlText) {
    final doc = loadYaml(yamlText);
    final map = <String, RegistryComponent>{};
    final comps = doc['components'];
    if (comps is YamlMap) {
      comps.forEach((k, v) {
        if (v is! YamlMap) return;
        final prov = v['provenance'];
        final dist = v['distribution'];
        String? get(Map? m, String key) =>
            m == null ? null : m[key]?.toString();
        map['$k'] = RegistryComponent(
          id: '$k',
          displayName: '${v['display_name'] ?? k}',
          updatePolicy: '${v['update_policy'] ?? 'reference_only'}',
          repository: get(prov, 'repository'),
          revision: get(prov, 'revision'),
          license: get(prov, 'license'),
          distributionType: get(dist, 'type'),
          assetPattern: get(dist, 'asset_pattern'),
          updateClass: v['update_class']?.toString(),
          patches: [
            if (v['patches'] is YamlList)
              for (final p in v['patches'] as YamlList) '$p',
          ],
        );
      });
    }
    return UpstreamRegistry(map);
  }
}
