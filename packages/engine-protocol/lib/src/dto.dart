/// Wire DTOs for DownloadEngine Protocol v1.
///
/// Deliberately decoupled from core-domain types — the protocol is a
/// versioned contract between processes; domain objects evolve
/// independently.
final class DownloadRequestDto {
  const DownloadRequestDto({
    required this.url,
    required this.targetDirectory,
    this.fileName,
    this.headers = const {},
    this.referer,
    this.userAgent,
    this.maxConnections,
    this.speedLimitBytesPerSecond,
    this.pageUrl,
  });

  final String url;
  final String targetDirectory;
  final String? fileName;
  final Map<String, String> headers;
  final String? referer;
  final String? userAgent;
  final int? maxConnections;
  final int? speedLimitBytesPerSecond;

  /// The page the download was captured on — persisted as
  /// DownloadSource.originalPageUrl so a URL-refresh resolver can
  /// re-derive an expired signed URL. Additive (v1-compatible).
  final String? pageUrl;

  factory DownloadRequestDto.fromJson(Map<String, Object?> json) =>
      DownloadRequestDto(
        url: json['url'] as String,
        targetDirectory: json['targetDirectory'] as String,
        fileName: json['fileName'] as String?,
        headers:
            (json['headers'] as Map?)?.cast<String, String>() ?? const {},
        referer: json['referer'] as String?,
        userAgent: json['userAgent'] as String?,
        maxConnections: json['maxConnections'] as int?,
        speedLimitBytesPerSecond:
            json['speedLimitBytesPerSecond'] as int?,
        pageUrl: json['pageUrl'] as String?,
      );

  Map<String, Object?> toJson() => {
        'url': url,
        'targetDirectory': targetDirectory,
        'fileName': fileName,
        'headers': headers,
        'referer': referer,
        'userAgent': userAgent,
        'maxConnections': maxConnections,
        'speedLimitBytesPerSecond': speedLimitBytesPerSecond,
        'pageUrl': pageUrl,
      };
}

/// engine.hello result (design doc §4.2).
final class EngineHello {
  const EngineHello({
    required this.protocol,
    required this.bundleId,
    required this.bundleVersion,
    required this.engineName,
    required this.engineRevision,
    required this.stateSchema,
    required this.capabilities,
  });

  final int protocol;
  final String bundleId;
  final String bundleVersion;
  final String engineName;
  final String engineRevision;
  final int stateSchema;
  final Map<String, Object?> capabilities;

  Map<String, Object?> toJson() => {
        'protocol': protocol,
        'bundleId': bundleId,
        'bundleVersion': bundleVersion,
        'engineName': engineName,
        'engineRevision': engineRevision,
        'stateSchema': stateSchema,
        'capabilities': capabilities,
      };
}
