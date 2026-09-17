import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_engine_host/engine_client.dart';
import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:freedm_update_api/freedm_update_api.dart';

/// View-model between the Flutter UI and the application layer.
/// Owns no download logic — it renders [DownloadScheduler] state and
/// forwards user intents (enqueue/pause/resume/cancel/refresh).
final class DesktopController extends ChangeNotifier {
  DesktopController({
    required DownloadScheduler scheduler,
    ComponentManager? components,
    EngineHostClient? mediaEngine,
    List<String> componentIds = const [
      'engine.brisk', 'media.ytdlp', 'media.ffmpeg'],
    required String downloadDir,
  })  : _scheduler = scheduler,
        _components = components,
        _mediaEngine = mediaEngine,
        _componentIds = componentIds,
        downloadDir = downloadDir {
    _sub = _scheduler.changes.listen((t) {
      _tasks[t.id.value] = t;
      notifyListeners();
    });
    _mediaSub = mediaEngine?.mediaTasks.listen((t) {
      _tasks[t.id.value] = t;
      notifyListeners();
    });
  }

  final DownloadScheduler _scheduler;
  final ComponentManager? _components;
  final EngineHostClient? _mediaEngine;
  final List<String> _componentIds;
  final String downloadDir;
  static const _classifier = MediaUrlClassifier();

  final _tasks = <String, DownloadTask>{};
  StreamSubscription<DownloadTask>? _sub;
  StreamSubscription<DownloadTask>? _mediaSub;
  final _componentStates = <String, ComponentState>{};
  String? lastError;

  /// Sorted for display: active first, then by creation time.
  List<DownloadTask> get tasks {
    final list = _tasks.values.toList()
      ..sort((a, b) {
        final act = a.status.isActive ? 0 : 1;
        final actB = b.status.isActive ? 0 : 1;
        if (act != actB) return act - actB;
        return b.createdAt.compareTo(a.createdAt);
      });
    return list;
  }

  Map<String, ComponentState> get componentStates =>
      Map.unmodifiable(_componentStates);

  Future<void> loadExisting() async {
    for (final t in await _scheduler.tasks()) {
      _tasks[t.id.value] = t;
    }
    await refreshComponents();
    notifyListeners();
  }

  Future<DownloadTask> addDownload(String url,
      {String? fileName}) async {
    final uri = Uri.tryParse(url);
    final cls =
        uri == null ? null : _classifier.classify(uri);
    final me = _mediaEngine;
    if (cls != null &&
        cls.needsResolver &&
        me != null &&
        me.supportsMedia) {
      // Media page → engine-host resolves + downloads + muxes.
      final id = await me.enqueueMedia(
          pageUrl: url, targetDirectory: downloadDir);
      final now = DateTime.now().toUtc();
      final task = DownloadTask(
        id: id,
        kind: TaskKind.media,
        status: DownloadStatus.created,
        source: DownloadSource(initialUrl: url),
        output: OutputSpec(targetDirectory: downloadDir),
        createdAt: now,
        updatedAt: now,
      );
      _tasks[id.value] = task;
      notifyListeners();
      return task;
    }
    final task = await _scheduler.enqueue(DownloadRequest(
      source: DownloadSource(initialUrl: url),
      output: OutputSpec(
          targetDirectory: downloadDir, fileName: fileName),
    ));
    _tasks[task.id.value] = task;
    notifyListeners();
    return task;
  }

  Future<void> pause(TaskId id) => _guard(() => _scheduler.pause(id));
  Future<void> resume(TaskId id) => _guard(() => _scheduler.resume(id));
  Future<void> cancel(TaskId id) => _guard(() async {
        final t = _tasks[id.value];
        if (t?.kind == TaskKind.media &&
            _mediaEngine?.supportsMedia == true) {
          await _mediaEngine!.cancelMedia(id);
        } else {
          await _scheduler.cancel(id);
        }
      });
  Future<void> remove(TaskId id) => _guard(() async {
        await _scheduler.remove(id);
        _tasks.remove(id.value);
        notifyListeners();
      });
  Future<void> refreshUrl(TaskId id) =>
      _guard(() => _scheduler.refreshSource(id));

  // ---- component manager ----

  Future<void> refreshComponents() async {
    final c = _components;
    if (c == null) return;
    for (final id in _componentIds) {
      _componentStates[id] = await c.state(id);
    }
    notifyListeners();
  }

  Future<UpdateResult?> updateComponent(String id) async {
    final c = _components;
    if (c == null) return null;
    final r = await c.update(id);
    await refreshComponents();
    return r;
  }

  Future<void> rollbackComponent(String id, String version) async {
    final c = _components;
    if (c == null) return;
    await c.rollback(id, version);
    await refreshComponents();
  }

  Future<void> togglePin(String id, bool pinned) async {
    final c = _components;
    if (c == null) return;
    await c.setPinned(id, pinned);
    await refreshComponents();
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      lastError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _mediaSub?.cancel();
    super.dispose();
  }
}

/// Presentation helpers — pure functions, unit-testable.
String fmtBytes(int? b) {
  if (b == null || b < 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var v = b.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
}

String fmtSpeed(int? bps) =>
    bps == null ? '' : '${fmtBytes(bps)}/s';

double taskProgress(DownloadTask t) {
  final total = t.totalBytes;
  if (total == null || total <= 0) return -1; // indeterminate
  return (t.receivedBytes / total).clamp(0.0, 1.0);
}

String taskFileName(DownloadTask t) {
  if (t.output.fileName != null) return t.output.fileName!;
  final seg = Uri.tryParse(t.source.effectiveUrl)?.pathSegments;
  final last = seg == null || seg.isEmpty ? '' : seg.last;
  return last.isEmpty ? 'download' : Uri.decodeComponent(last);
}
