import 'download_task.dart';
import 'task_id.dart';

/// Persistence port — owned by core-domain, implemented by
/// packages/persistence (SQLite) in M4. No SQL types leak here.
abstract interface class TaskRepository {
  Future<void> upsert(DownloadTask task);
  Future<DownloadTask?> get(TaskId id);
  Future<List<DownloadTask>> list({String? queueId});
  Future<void> delete(TaskId id);

  /// Tasks needing recovery after a restart (non-terminal states).
  Future<List<DownloadTask>> listActive();

  /// Task ids still referencing a given engine bundle — used by the
  /// component GC so referenced old bundles are never deleted
  /// (design doc §31.1).
  Future<int> countByEngineBundle(String componentId, String version);
}
