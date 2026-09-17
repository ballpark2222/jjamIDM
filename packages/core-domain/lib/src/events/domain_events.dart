import '../task/task_id.dart';

/// Domain events (design doc §24). Published on the Event Bus by the
/// application layer after state-machine transitions — adapters never
/// publish these directly.
sealed class DomainEvent {
  const DomainEvent(this.taskId, this.at);
  final TaskId taskId;
  final DateTime at;
}

final class DownloadCreated extends DomainEvent {
  const DownloadCreated(super.taskId, super.at);
}

final class DownloadResolved extends DomainEvent {
  const DownloadResolved(super.taskId, super.at, {this.finalUrl});
  final String? finalUrl;
}

final class DownloadStarted extends DomainEvent {
  const DownloadStarted(super.taskId, super.at);
}

final class DownloadPaused extends DomainEvent {
  const DownloadPaused(super.taskId, super.at);
}

final class DownloadResumed extends DomainEvent {
  const DownloadResumed(super.taskId, super.at);
}

final class DownloadRetryScheduled extends DomainEvent {
  const DownloadRetryScheduled(super.taskId, super.at, {required this.attempt});
  final int attempt;
}

final class DownloadUrlExpired extends DomainEvent {
  const DownloadUrlExpired(super.taskId, super.at);
}

final class DownloadVerified extends DomainEvent {
  const DownloadVerified(super.taskId, super.at);
}

final class DownloadCompleted extends DomainEvent {
  const DownloadCompleted(super.taskId, super.at, {this.outputPath});
  final String? outputPath;
}

final class DownloadFailed extends DomainEvent {
  const DownloadFailed(super.taskId, super.at, {required this.error});
  final Object error;
}

// Non-task events (design doc §24) — separate sealed family.
sealed class SystemEvent {
  const SystemEvent(this.at);
  final DateTime at;
}

final class ComponentCandidateFound extends SystemEvent {
  const ComponentCandidateFound(
    super.at, {
    required this.componentId,
    required this.version,
  });
  final String componentId;
  final String version;
}

final class ComponentUpdated extends SystemEvent {
  const ComponentUpdated(
    super.at, {
    required this.componentId,
    required this.fromVersion,
    required this.toVersion,
  });
  final String componentId;
  final String fromVersion;
  final String toVersion;
}

final class ComponentRolledBack extends SystemEvent {
  const ComponentRolledBack(
    super.at, {
    required this.componentId,
    required this.toVersion,
  });
  final String componentId;
  final String toVersion;
}
