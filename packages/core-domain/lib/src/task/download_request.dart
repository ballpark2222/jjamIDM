import 'download_source.dart';
import 'output_spec.dart';

/// Immutable request handed to a DownloadEngine. Credentials travel
/// by reference only (design doc §14).
final class DownloadRequest {
  const DownloadRequest({
    required this.source,
    required this.output,
    this.headers = const {},
    this.maxConnections,
    this.speedLimitBytesPerSecond,
  });

  final DownloadSource source;
  final OutputSpec output;

  /// Resolved request headers (Cookie/Referer/Authorization/…).
  ///
  /// TRANSIENT — populated by the application layer from the
  /// CredentialStore right before engine dispatch. NEVER persisted;
  /// the DB stores only credentialRef/headersRef (design doc §14).
  final Map<String, String> headers;

  /// null = engine default / auto.
  final int? maxConnections;
  final int? speedLimitBytesPerSecond;
}
