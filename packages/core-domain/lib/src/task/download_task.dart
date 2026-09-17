import 'download_source.dart';
import 'download_status.dart';
import 'error_code.dart';
import 'output_spec.dart';
import 'retry_policy.dart';
import 'task_id.dart';

enum TaskKind { file, media, torrent }

/// Aggregate root of a download (design doc §8).
///
/// Immutable: mutations go through [copyWith] inside a state-machine
/// transition performed by the application layer.
final class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.kind,
    required this.status,
    required this.source,
    required this.output,
    required this.createdAt,
    required this.updatedAt,
    this.priority = 0,
    this.queueId,
    this.providerId,
    this.retryPolicy = const RetryPolicy(),
    this.credentialRef,
    this.metadata = const {},
    this.receivedBytes = 0,
    this.totalBytes,
    this.failedAttempts = 0,
    this.lastError = ErrorCode.none,
    this.engineComponentId,
    this.engineBundleVersion,
    this.engineStateSchema,
  });

  final TaskId id;
  final TaskKind kind;
  final DownloadStatus status;
  final DownloadSource source;
  final OutputSpec output;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Higher = earlier in queue.
  final int priority;
  final String? queueId;

  /// e.g. `engine.brisk` — capability lookup only, never a type check.
  final String? providerId;

  final RetryPolicy retryPolicy;
  final String? credentialRef;
  final Map<String, String> metadata;

  // progress snapshot (streams carry live data; this is persisted)
  final int receivedBytes;
  final int? totalBytes;

  final int failedAttempts;
  final ErrorCode lastError;

  // Engine affinity for safe component updates (design doc §31.1).
  final String? engineComponentId;
  final String? engineBundleVersion;
  final int? engineStateSchema;

  double? get progress => (totalBytes != null && totalBytes! > 0)
      ? receivedBytes / totalBytes!
      : null;

  DownloadTask copyWith({
    TaskKind? kind,
    DownloadStatus? status,
    DownloadSource? source,
    OutputSpec? output,
    DateTime? updatedAt,
    int? priority,
    String? queueId,
    String? providerId,
    RetryPolicy? retryPolicy,
    String? credentialRef,
    Map<String, String>? metadata,
    int? receivedBytes,
    int? totalBytes,
    int? failedAttempts,
    ErrorCode? lastError,
    String? engineComponentId,
    String? engineBundleVersion,
    int? engineStateSchema,
  }) => DownloadTask(
    id: id,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    source: source ?? this.source,
    output: output ?? this.output,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    priority: priority ?? this.priority,
    queueId: queueId ?? this.queueId,
    providerId: providerId ?? this.providerId,
    retryPolicy: retryPolicy ?? this.retryPolicy,
    credentialRef: credentialRef ?? this.credentialRef,
    metadata: metadata ?? this.metadata,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    failedAttempts: failedAttempts ?? this.failedAttempts,
    lastError: lastError ?? this.lastError,
    engineComponentId: engineComponentId ?? this.engineComponentId,
    engineBundleVersion: engineBundleVersion ?? this.engineBundleVersion,
    engineStateSchema: engineStateSchema ?? this.engineStateSchema,
  );
}
