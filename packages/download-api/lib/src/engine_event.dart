import 'package:freedm_core_domain/freedm_core_domain.dart';

/// Events an engine reports back over [DownloadEngine.events].
/// The application layer maps these to state-machine transitions;
/// engines never touch task state.
sealed class EngineEvent {
  const EngineEvent();
}

final class EngineProgress extends EngineEvent {
  const EngineProgress({
    required this.receivedBytes,
    this.totalBytes,
    this.speedBytesPerSecond,
    this.activeConnections,
  });
  final int receivedBytes;
  final int? totalBytes;
  final int? speedBytesPerSecond;
  final int? activeConnections;
}

final class EngineResolved extends EngineEvent {
  const EngineResolved({
    this.finalUrl,
    this.fileName,
    this.totalBytes,
    this.etag,
    this.lastModified,
    this.contentType,
    this.acceptsRanges,
  });
  final String? finalUrl;
  final String? fileName;
  final int? totalBytes;
  final String? etag;
  final String? lastModified;
  final String? contentType;
  final bool? acceptsRanges;
}

final class EngineCompleted extends EngineEvent {
  const EngineCompleted({this.outputPath});
  final String? outputPath;
}

final class EnginePaused extends EngineEvent {
  const EnginePaused();
}

final class EngineFailed extends EngineEvent {
  const EngineFailed(this.error, {this.detail});
  final ErrorCode error;
  final String? detail;
}
