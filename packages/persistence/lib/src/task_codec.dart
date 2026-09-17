import 'package:freedm_core_domain/freedm_core_domain.dart';

/// DownloadTask <-> JSON. Versioned via [schemaVersion] so future
/// migrations can detect older payloads (design doc §30).
final class TaskCodec {
  const TaskCodec._();

  static const int schemaVersion = 1;

  static Map<String, Object?> encode(DownloadTask t) => {
        'schema': schemaVersion,
        'id': t.id.value,
        'kind': t.kind.name,
        'status': t.status.name,
        'source': _source(t.source),
        'output': _output(t.output),
        'createdAt': t.createdAt.toIso8601String(),
        'updatedAt': t.updatedAt.toIso8601String(),
        'priority': t.priority,
        'queueId': t.queueId,
        'providerId': t.providerId,
        'retryPolicy': _retry(t.retryPolicy),
        'credentialRef': t.credentialRef,
        'metadata': t.metadata,
        'receivedBytes': t.receivedBytes,
        'totalBytes': t.totalBytes,
        'failedAttempts': t.failedAttempts,
        'lastError': t.lastError.name,
        'engineComponentId': t.engineComponentId,
        'engineBundleVersion': t.engineBundleVersion,
        'engineStateSchema': t.engineStateSchema,
      };

  static DownloadTask decode(Map<String, Object?> j) {
    final schema = j['schema'] as int? ?? 0;
    if (schema > schemaVersion) {
      throw FormatException('task schema $schema newer than supported');
    }
    T enumOf<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    return DownloadTask(
      id: TaskId(j['id'] as String),
      kind: enumOf(TaskKind.values, j['kind'], TaskKind.file),
      status: enumOf(
          DownloadStatus.values, j['status'], DownloadStatus.created),
      source: _sourceIn(j['source'] as Map<String, Object?>),
      output: _outputIn(j['output'] as Map<String, Object?>),
      createdAt: DateTime.parse(j['createdAt'] as String),
      updatedAt: DateTime.parse(j['updatedAt'] as String),
      priority: j['priority'] as int? ?? 0,
      queueId: j['queueId'] as String?,
      providerId: j['providerId'] as String?,
      retryPolicy: _retryIn(j['retryPolicy'] as Map<String, Object?>?),
      credentialRef: j['credentialRef'] as String?,
      metadata: (j['metadata'] as Map?)?.cast<String, String>() ?? {},
      receivedBytes: j['receivedBytes'] as int? ?? 0,
      totalBytes: j['totalBytes'] as int?,
      failedAttempts: j['failedAttempts'] as int? ?? 0,
      lastError: enumOf(ErrorCode.values, j['lastError'], ErrorCode.none),
      engineComponentId: j['engineComponentId'] as String?,
      engineBundleVersion: j['engineBundleVersion'] as String?,
      engineStateSchema: j['engineStateSchema'] as int?,
    );
  }

  static Map<String, Object?> _source(DownloadSource s) => {
        'initialUrl': s.initialUrl,
        'originalPageUrl': s.originalPageUrl,
        'currentUrl': s.currentUrl,
        'finalUrl': s.finalUrl,
        'referer': s.referer,
        'userAgent': s.userAgent,
        'headersRef': s.headersRef,
        'credentialRef': s.credentialRef,
        'etag': s.etag,
        'lastModified': s.lastModified,
        'contentLength': s.contentLength,
        'contentType': s.contentType,
      };

  static DownloadSource _sourceIn(Map<String, Object?> j) =>
      DownloadSource(
        initialUrl: j['initialUrl'] as String,
        originalPageUrl: j['originalPageUrl'] as String?,
        currentUrl: j['currentUrl'] as String?,
        finalUrl: j['finalUrl'] as String?,
        referer: j['referer'] as String?,
        userAgent: j['userAgent'] as String?,
        headersRef: j['headersRef'] as String?,
        credentialRef: j['credentialRef'] as String?,
        etag: j['etag'] as String?,
        lastModified: j['lastModified'] as String?,
        contentLength: j['contentLength'] as int?,
        contentType: j['contentType'] as String?,
      );

  static Map<String, Object?> _output(OutputSpec o) => {
        'targetDirectory': o.targetDirectory,
        'fileName': o.fileName,
        'conflictPolicy': o.conflictPolicy.name,
        'expectedSize': o.expectedSize,
        'checksum': o.checksum,
      };

  static OutputSpec _outputIn(Map<String, Object?> j) => OutputSpec(
        targetDirectory: j['targetDirectory'] as String,
        fileName: j['fileName'] as String?,
        conflictPolicy: ConflictPolicy.values.firstWhere(
          (v) => v.name == j['conflictPolicy'],
          orElse: () => ConflictPolicy.rename,
        ),
        expectedSize: j['expectedSize'] as int?,
        checksum: j['checksum'] as String?,
      );

  static Map<String, Object?> _retry(RetryPolicy r) => {
        'maxAttempts': r.maxAttempts,
        'initialDelayMs': r.initialDelay.inMilliseconds,
        'backoffFactor': r.backoffFactor,
        'maxDelayMs': r.maxDelay.inMilliseconds,
      };

  static RetryPolicy _retryIn(Map<String, Object?>? j) => j == null
      ? const RetryPolicy()
      : RetryPolicy(
          maxAttempts: j['maxAttempts'] as int? ?? 5,
          initialDelay:
              Duration(milliseconds: j['initialDelayMs'] as int? ?? 2000),
          backoffFactor: (j['backoffFactor'] as num?)?.toDouble() ?? 2.0,
          maxDelay: Duration(
              milliseconds: j['maxDelayMs'] as int? ?? 300000),
        );
}
