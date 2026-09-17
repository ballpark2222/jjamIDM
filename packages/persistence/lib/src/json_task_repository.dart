import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:path/path.dart' as p;

import 'task_codec.dart';

/// TaskRepository backed by a single JSON file — the pre-SQLite store.
///
/// Writes are atomic (temp file + rename) and serialized through an
/// internal write queue so concurrent upserts can't interleave.
/// Only task metadata is persisted: DownloadTask carries
/// credentialRef/headersRef, never secrets (design doc §14).
final class JsonTaskRepository implements TaskRepository {
  JsonTaskRepository._(this._file, this._tasks);

  final File _file;
  final Map<String, DownloadTask> _tasks;
  Future<void> _writeQueue = Future<void>.value();

  static Future<JsonTaskRepository> open(Directory dir) async {
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'tasks.json'));
    final tasks = <String, DownloadTask>{};
    if (await file.exists()) {
      final raw = await file.readAsString();
      if (raw.trim().isNotEmpty) {
        final list = jsonDecode(raw) as List;
        for (final e in list) {
          final task =
              TaskCodec.decode((e as Map).cast<String, Object?>());
          tasks[task.id.value] = task;
        }
      }
    }
    return JsonTaskRepository._(file, tasks);
  }

  /// Outstanding writes — callers that need durability (tests,
  /// shutdown) await this before touching the file.
  Future<void> get pending => _writeQueue;

  Future<void> _flush() {
    final encoded = jsonEncode(
      _tasks.values.map(TaskCodec.encode).toList(),
    );
    _writeQueue = _writeQueue.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(encoded);
      // Windows rename() cannot overwrite — rotate through .bak so a
      // crash mid-flush still leaves a readable store.
      if (await _file.exists()) {
        final bak = File('${_file.path}.bak');
        if (await bak.exists()) await bak.delete();
        await _file.rename(bak.path);
      }
      await tmp.rename(_file.path);
    });
    return _writeQueue;
  }

  @override
  Future<void> upsert(DownloadTask task) {
    _tasks[task.id.value] = task;
    return _flush();
  }

  @override
  Future<DownloadTask?> get(TaskId id) async => _tasks[id.value];

  @override
  Future<List<DownloadTask>> list({String? queueId}) async =>
      _tasks.values
          .where((t) => queueId == null || t.queueId == queueId)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> delete(TaskId id) {
    _tasks.remove(id.value);
    return _flush();
  }

  @override
  Future<List<DownloadTask>> listActive() async => _tasks.values
      .where((t) =>
          t.status.isActive ||
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.retryWait ||
          t.status == DownloadStatus.ready)
      .toList();

  @override
  Future<int> countByEngineBundle(
      String componentId, String version) async =>
      _tasks.values
          .where((t) =>
              t.engineComponentId == componentId &&
              t.engineBundleVersion == version)
          .length;
}
