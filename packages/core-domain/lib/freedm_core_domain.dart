/// FreeDM core domain — pure, deterministic, no I/O.
///
/// Dependency rule: this package may not import adapters, engines,
/// transport, or platform APIs. Ports it owns: [TaskRepository],
/// [TaskIdGenerator].
library;

export 'src/events/domain_events.dart';
export 'src/task/download_request.dart';
export 'src/task/download_source.dart';
export 'src/task/download_status.dart';
export 'src/task/download_task.dart';
export 'src/task/error_code.dart';
export 'src/task/output_spec.dart';
export 'src/task/retry_policy.dart';
export 'src/task/task_id.dart';
export 'src/task/task_repository.dart';
export 'src/task/task_state_machine.dart';
