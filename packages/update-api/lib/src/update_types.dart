/// Component manager types (design doc §21). A "component" is an
/// independently updatable bundle: engine.brisk, media.ytdlp,
/// media.ffmpeg, native-host, extension, freedm app itself.
library;

/// An update candidate advertised by an upstream source.
final class ComponentCandidate {
  const ComponentCandidate({
    required this.componentId,
    required this.version,
    required this.bundleUrl,
    required this.sha256,
    this.signature,
    this.sizeBytes,
  });

  final String componentId;
  final String version;
  final String bundleUrl;

  /// Lowercase hex sha256 of the bundle bytes — mandatory; the
  /// manager refuses candidates without one.
  final String sha256;

  /// Detached signature (format owned by [SignatureVerifier]).
  final String? signature;
  final int? sizeBytes;
}

/// On-disk record of one installed component version.
final class InstalledComponent {
  const InstalledComponent({
    required this.componentId,
    required this.version,
    required this.path,
    required this.installedAt,
    this.activeTaskRefs = 0,
  });

  final String componentId;
  final String version;
  final String path;
  final DateTime installedAt;

  /// Engine-affinity counter (design doc §21): tasks bound to an
  /// engine build pin its bundle until they finish.
  final int activeTaskRefs;

  InstalledComponent copyWith({int? activeTaskRefs}) =>
      InstalledComponent(
        componentId: componentId,
        version: version,
        path: path,
        installedAt: installedAt,
        activeTaskRefs: activeTaskRefs ?? this.activeTaskRefs,
      );
}

/// Per-component state: which versions exist, which is active,
/// whether auto-update is pinned off.
final class ComponentState {
  const ComponentState({
    required this.componentId,
    this.activeVersion,
    this.pinned = false,
    this.installed = const {},
  });

  final String componentId;
  final String? activeVersion;
  final bool pinned;
  final Map<String, InstalledComponent> installed;

  ComponentState copyWith({
    String? activeVersion,
    bool? pinned,
    Map<String, InstalledComponent>? installed,
  }) =>
      ComponentState(
        componentId: componentId,
        activeVersion: activeVersion ?? this.activeVersion,
        pinned: pinned ?? this.pinned,
        installed: installed ?? this.installed,
      );

  InstalledComponent? get active =>
      activeVersion == null ? null : installed[activeVersion];
}

enum UpdateOutcome {
  updated,
  alreadyCurrent,
  pinned,
  verifyFailed,
  fetchFailed,
}

final class UpdateResult {
  const UpdateResult(this.outcome, {this.version, this.detail});
  final UpdateOutcome outcome;
  final String? version;
  final String? detail;
  bool get ok =>
      outcome == UpdateOutcome.updated ||
      outcome == UpdateOutcome.alreadyCurrent;
}
