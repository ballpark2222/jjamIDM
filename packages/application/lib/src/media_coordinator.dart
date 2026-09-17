import 'dart:async';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_media_api/freedm_media_api.dart';

/// Drives a media task through the media pipeline (design doc §18):
///   resolvingMedia → downloadingVideo/Audio (engine or component
///   step) → muxing → subtitleProcessing → verifying → completed.
///
/// Runs alongside [DownloadScheduler]: the coordinator owns the task
/// while a plan executes; file-pipeline queueing still belongs to the
/// scheduler. All transitions go through [TaskStateMachine].
final class MediaDownloadCoordinator {
  MediaDownloadCoordinator({
    required DownloadEngine engine,
    required TaskRepository repository,
    required EventBus eventBus,
    required MediaResolver resolver,
    required MediaMuxer muxer,
    Map<String, ComponentDownloader> componentDownloaders = const {},
    DateTime Function()? clock,
  })  : _engine = engine,
        _repo = repository,
        _bus = eventBus,
        _resolver = resolver,
        _muxer = muxer,
        _downloaders = componentDownloaders,
        _clock = clock ?? DateTime.now;

  final DownloadEngine _engine;
  final TaskRepository _repo;
  final EventBus _bus;
  final MediaResolver _resolver;
  final MediaMuxer _muxer;
  final Map<String, ComponentDownloader> _downloaders;
  final DateTime Function() _clock;
  final _sm = const TaskStateMachine();

  final _tasks = <String, DownloadTask>{};
  final _changes = StreamController<DownloadTask>.broadcast();

  /// Task updates for UI.
  Stream<DownloadTask> get changes => _changes.stream;

  DownloadTask? task(TaskId id) => _tasks[id.value];

  /// Resolve a media page through the configured [MediaResolver].
  Future<MediaProbe> probe(String pageUrl,
          {Map<String, String> headers = const {}}) =>
      _resolver.probe(pageUrl, headers: headers);

  /// Create a media task and run its plan to completion (or failure).
  /// [workDir] holds intermediate video/audio/subtitle artifacts.
  Future<DownloadTask> enqueueMedia(
    MediaSelection selection, {
    required String workDir,
    required String targetDirectory,
    int priority = 0,
    String? queueId,
  }) async {
    final now = _clock().toUtc();
    var task = DownloadTask(
      id: TaskId('m${now.microsecondsSinceEpoch}'),
      kind: TaskKind.media,
      status: DownloadStatus.created,
      source: DownloadSource(initialUrl: selection.pageUrl),
      output: OutputSpec(targetDirectory: targetDirectory),
      createdAt: now,
      updatedAt: now,
      priority: priority,
      queueId: queueId,
      providerId: _resolver.providerId,
    );
    _tasks[task.id.value] = task;
    await _repo.upsert(task);
    _bus.publish(DownloadCreated(task.id, now));
    unawaited(_run(task, selection, workDir));
    return task;
  }

  Future<void> cancel(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null || t.status.isTerminal) return;
    if (t.status.isActive) await _engine.cancel(id);
    _apply(t, DownloadStatus.cancelled);
  }

  Future<void> dispose() => _changes.close();

  // ------------------------------------------------------------------

  Future<void> _run(
      DownloadTask task, MediaSelection sel, String workDir) async {
    await Directory(workDir).create(recursive: true);
    try {
      task = _apply(task, DownloadStatus.resolvingMedia);
      final plan = await _resolver.plan(sel);
      // ready is the gate state between resolution and downloads.
      task = _apply(task, DownloadStatus.ready);
      final produced = <String>[]; // artifact paths, in plan order
      final subtitles = <String>[];

      for (final step in plan.steps) {
        task = _tasks[task.id.value] ?? task;
        if (task.status.isTerminal) return;
        switch (step) {
          case EngineDownloadStep():
            final path = await _engineStep(task, step, workDir);
            task = _tasks[task.id.value]!;
            if (step.role == 'subtitle') {
              subtitles.add(path);
            } else {
              produced.add(path);
            }
          case ComponentDownloadStep():
            final path = await _componentStep(task, step, workDir, sel);
            task = _tasks[task.id.value]!;
            produced.add(path);
          case MuxStep():
            task = _to(task, DownloadStatus.muxing);
            final r = await _muxer.mux(step, workDir: workDir);
            if (!r.ok) {
              _fail(task, ErrorCode.unknown, r.error ?? 'mux failed');
              return;
            }
            task = _tasks[task.id.value]!;
            if (r.outputPath != null) produced.add(r.outputPath!);
        }
      }

      // Subtitle stage — attach selected langs as files.
      if (sel.subtitleLangs.isNotEmpty && produced.isNotEmpty) {
        task = _to(task, DownloadStatus.subtitleProcessing);
        final video = produced.last;
        final r = await _muxer.attachSubtitles(video, subtitles);
        if (!r.ok) {
          _fail(task, ErrorCode.unknown, r.error ?? 'subtitle failed');
          return;
        }
        if (r.outputPath != null) produced.add(r.outputPath!);
        task = _tasks[task.id.value]!;
      }

      // Deliver the final artifact to the user's target directory.
      String? delivered;
      if (produced.isNotEmpty) {
        await Directory(task.output.targetDirectory)
            .create(recursive: true);
        final src = produced.last;
        var name = plan.finalFileName;
        if (!name.contains('.')) {
          final dot = src.lastIndexOf('.');
          if (dot > src.lastIndexOf(Platform.pathSeparator)) {
            name += src.substring(dot); // keep container ext
          }
        }
        final dest =
            '${task.output.targetDirectory}${Platform.pathSeparator}$name';
        delivered = await File(src).rename(dest).then((f) => f.path)
            .catchError((_) async {
          // cross-device fallback
          await File(src).copy(dest);
          await File(src).delete();
          return dest;
        });
      }

      task = _to(task, DownloadStatus.verifying);
      _apply(task, DownloadStatus.completed);
      _bus.publish(DownloadCompleted(task.id, _clock().toUtc(),
          outputPath: delivered ??
              (produced.isEmpty ? null : produced.last)));
    } catch (e) {
      final cur = _tasks[task.id.value] ?? task;
      if (!cur.status.isTerminal) {
        _fail(cur, ErrorCode.unknown, '$e');
      }
    }
  }

  /// Normalize to [to]: skips self-transitions and routes through
  /// downloadingVideo when the direct edge isn't in the table
  /// (e.g. ready→downloadingAudio).
  DownloadTask _to(DownloadTask t, DownloadStatus to) {
    if (t.status == to) return t;
    if (!_sm.canTransition(t.status, to)) {
      t = _apply(t, DownloadStatus.downloadingVideo);
    }
    return t.status == to ? t : _apply(t, to);
  }

  Future<String> _engineStep(
      DownloadTask task, EngineDownloadStep step, String workDir) async {
    task = _to(task, step.role == 'audio'
        ? DownloadStatus.downloadingAudio
        : DownloadStatus.downloadingVideo);
    final req = DownloadRequest(
      source: DownloadSource(initialUrl: step.url),
      output: OutputSpec(
          targetDirectory: workDir, fileName: step.outputFileName),
      headers: step.headers,
    );
    await _engine.create(task.id, req);
    final done = Completer<String>();
    final sub = _engine.events(task.id).listen((e) {
      if (e is EngineCompleted && !done.isCompleted) {
        done.complete(e.outputPath ??
            '$workDir${Platform.pathSeparator}${step.outputFileName}');
      }
      if (e is EngineFailed && !done.isCompleted) {
        done.completeError(StateError(e.detail ?? e.error.name));
      }
    });
    await _engine.start(task.id);
    try {
      return await done.future;
    } finally {
      await sub.cancel();
    }
  }

  Future<String> _componentStep(DownloadTask task,
      ComponentDownloadStep step, String workDir,
      MediaSelection sel) async {
    task = _to(task, DownloadStatus.downloadingVideo);
    final dl = _downloaders[step.componentId];
    if (dl == null) {
      throw StateError(
          'no downloader registered for ${step.componentId}');
    }
    final path =
        '$workDir${Platform.pathSeparator}${step.outputFileName}';
    final code = await dl.download(
        pageUrl: sel.pageUrl,
        outputPath: path,
        formatId: step.formatId);
    if (code != 0) {
      throw StateError('${step.componentId} exited $code');
    }
    return path;
  }

  DownloadTask _apply(DownloadTask t, DownloadStatus to,
      {ErrorCode? lastError}) {
    final u = _sm.transition(t, to,
        at: _clock().toUtc(), lastError: lastError);
    _tasks[t.id.value] = u;
    if (!_changes.isClosed) _changes.add(u);
    unawaited(_repo.upsert(u));
    return u;
  }

  void _fail(DownloadTask t, ErrorCode code, String detail) {
    _apply(t, DownloadStatus.failed, lastError: code);
    _bus.publish(DownloadFailed(t.id, _clock().toUtc(), error: code));
  }
}
