import 'download_source.dart';
import 'output_spec.dart';

/// Immutable request handed to a DownloadEngine. Credentials travel
/// by reference only (design doc §14).
final class DownloadRequest {
  const DownloadRequest({
    required this.source,
    required this.output,
    this.maxConnections,
    this.speedLimitBytesPerSecond,
  });

  final DownloadSource source;
  final OutputSpec output;

  /// null = engine default / auto.
  final int? maxConnections;
  final int? speedLimitBytesPerSecond;
}
