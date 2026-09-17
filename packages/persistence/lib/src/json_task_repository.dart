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
    // _flush rotates tasks.json → .bak before renaming the tmp file
    // into place; a crash in that window leaves only .bak. Restore
    // it instead of opening an empty store and losing the queue.
    final bak = File('${file.path}.bak');
    File? src;
    if (await file.exists()) {
      src = file;
    } else if (await bak.exists()) {
      try {
        await bak.rename(file.path);
        src = file;
      } catch (_) {
        src = bak; // locked — read the backup in place
      }
    }
    final tasks = <String, DownloadTask>{};
    if (src != null) {
      try {
        final raw = await src.readAsString();
        if (raw.trim().isNotEmpty) {
          final list = jsonDecode(raw) as List;
          for (final e in list) {
            try {
              final task =
                  TaskCodec.decode((e as Map).cast<String, Object?>());
              tasks[task.id.value] = task;
            } catch (_) {
              // One unparseable entry must not cost the whole queue.
            }
          }
        }
      } catch (_) {
        // A corrupt store must not brick host startup — open empty.
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
    final run = _writeQueue.then((_) async {
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
    // Keep the chain alive after a failed write — a _writeQueue that
    // completes with an error would silently swallow every later
    // flush. The caller still observes this failure via [run].
    _writeQueue = run.catchError((_) {});
    return run;
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
          // created = enqueued with autoStart off (download-later);
          // recover() parks them back into memory.
          t.status == DownloadStatus.created ||
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.retryWait ||
          t.status == DownloadStatus.ready ||
          // urlExpired is a parked state awaiting refresh — without
          // it a crash mid-refresh strands the task forever.
          t.status == DownloadStatus.urlExpired)
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
