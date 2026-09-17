import 'package:freedm_core_domain/freedm_core_domain.dart';

import 'engine_capabilities.dart';
import 'engine_event.dart';

/// Result of probing a URL without starting a download.
final class ProbeResult {
  const ProbeResult({
    required this.supported,
    this.fileName,
    this.totalBytes,
    this.acceptsRanges,
    this.finalUrl,
    this.contentType,
  });
  final bool supported;
  final String? fileName;
  final int? totalBytes;
  final bool? acceptsRanges;
  final String? finalUrl;
  final String? contentType;
}

/// Handle returned by [DownloadEngine.create] — the engine-side id
/// for an in-flight or resumable download.
final class EngineTaskHandle {
  const EngineTaskHandle({required this.engineTaskId});
  final String engineTaskId;
}

/// Port: the download engine contract (design doc §10).
///
/// Implementations live in `packages/adapter-*` and run inside
/// `apps/engine-host`, reachable over DownloadEngine Protocol v1.
abstract interface class DownloadEngine {
  /// e.g. `engine.brisk` — informational only; capability checks use
  /// [capabilities], never this id.
  String get providerId;

  /// DownloadEngine Protocol version spoken by this engine.
  int get apiVersion;

  Future<EngineCapabilities> capabilities();

  /// Inspect URL headers without downloading (range support, size…).
  Future<ProbeResult> probe(DownloadRequest request);

  /// Allocate engine state for [id]+[request]; nothing starts yet.
  /// The same [id] must be used for all later calls on this task.
  Future<EngineTaskHandle> create(TaskId id, DownloadRequest request);

  Future<void> start(TaskId id);
  Future<void> pause(TaskId id);
  Future<void> resume(TaskId id);
  Future<void> cancel(TaskId id);

  /// Persist engine-side resume state (checkpoint) for restart-resume.
  Future<void> checkpoint(TaskId id);

  /// Replace the source URL after URL_EXPIRED (design doc §20).
  /// The engine must continue from the existing partial file.
  Future<void> replaceSource(TaskId id, DownloadRequest newRequest);

  Future<void> setSpeedLimit(TaskId id, int? bytesPerSecond);

  /// Live event stream for [id] — progress, resolution, completion,
  /// failure. Ends when the task reaches a terminal engine state.
  Stream<EngineEvent> events(TaskId id);
}
