/// Value identity of a [DownloadTask].
///
/// Generation is injected ([TaskIdGenerator]) so core-domain stays
/// deterministic and dependency-free.
final class TaskId {
  const TaskId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is TaskId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TaskId($value)';
}

/// Generates unique task ids. Provided by the application layer
/// (uuid, database sequence, test counter...).
typedef TaskIdGenerator = TaskId Function();
