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
/// In-flight run state for a media task — survives pause/resume so
/// a resumed task continues from the next unfinished plan step.
final class _MediaRun {
  _MediaRun(this.sel, this.workDir);
  final MediaSelection sel;
  final String workDir;
  MediaPlan? plan;
  var stepIndex = 0;
  final produced = <String>[];
  final subtitles = <String>[];
  var pauseRequested = false;
  CancellationToken? stepCancel;
  var engineStepActive = false;

  /// True only while the engine-side task is actually running —
  /// pausing before start crashes the engine (its per-task maps
  /// populate inside start), so pause() must gate on this, not on
  /// engineStepActive.
  var engineStarted = false;

  /// Set when an engine step was paused in place — resume must
  /// call `engine.resume`, not `create`+`start` (a fresh create
  /// would re-probe a possibly-expired URL and lose the engine's
  /// in-memory item state for that step).
  var enginePaused = false;
}

/// Thrown by a step when its pause/cancel sentinel fires — _run
/// turns it into the `paused` state instead of a failure.
final class _MediaPaused implements Exception {}

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
  final _runs = <String, _MediaRun>{};
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
    _runs[task.id.value] = _MediaRun(selection, workDir);
    await _repo.upsert(task);
    _bus.publish(DownloadCreated(task.id, now));
    unawaited(_run(task));
    return task;
  }

  Future<void> cancel(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null || t.status.isTerminal) return;
    final run = _runs[id.value];
    run?.stepCancel?.cancel();
    // isActive misses `paused` — a paused engine step still holds
    // the task id inside the engine, so consult it directly.
    if (t.status.isActive || run?.enginePaused == true) {
      try {
        await _engine.cancel(id);
      } catch (_) {}
    }
    _apply(t, DownloadStatus.cancelled);
    _runs.remove(id.value);
  }

  /// Pause a media task. Only download steps are pausable — a pause
  /// requested during resolve/mux lands at the next step boundary.
  /// Engine steps pause in place; component steps kill the yt-dlp
  /// process and resume from its `.part` artifacts on [resume].
  Future<void> pause(TaskId id) async {
    final t = _tasks[id.value];
    final run = _runs[id.value];
    if (t == null || run == null) {
      throw StateError('unknown task ${id.value}');
    }
    if (t.status.isTerminal) return;
    run.pauseRequested = true;
    if (t.status == DownloadStatus.downloadingVideo ||
        t.status == DownloadStatus.downloadingAudio) {
      if (run.engineStarted) {
        await _engine.pause(id);
        run.enginePaused = true;
      }
      run.stepCancel?.cancel();
    }
  }

  /// Resume a paused media task — continues the plan at the step it
  /// stopped on. yt-dlp component steps re-invoke with identical
  /// arguments and pick up from `.part` files in workDir.
  Future<void> resume(TaskId id) async {
    final t = _tasks[id.value];
    final run = _runs[id.value];
    if (t == null || run == null) {
      throw StateError('unknown task ${id.value}');
    }
    if (t.status != DownloadStatus.paused) return;
    run.pauseRequested = false;
    final resumed = _apply(t, DownloadStatus.downloadingVideo);
    _bus.publish(DownloadResumed(id, _clock().toUtc()));
    unawaited(_runSteps(resumed, run));
  }

  /// Mark interrupted media tasks after a host restart — run state
  /// lives in memory so an in-flight pipeline can't resume; engine
  /// temp segments still allow a future retry to redownload cleanly.
  Future<void> recover() async {
    for (final t in await _repo.listActive()) {
      if (t.status.isTerminal) continue;
      _tasks[t.id.value] = t;
      try {
        _apply(t, DownloadStatus.failed,
            lastError: ErrorCode.engineUnavailable);
      } on InvalidTransitionError {
        _apply(t, DownloadStatus.cancelled);
      }
    }
  }

  Future<void> dispose() => _changes.close();

  // ------------------------------------------------------------------

  Future<void> _run(DownloadTask task) async {
    final run = _runs[task.id.value]!;
    await Directory(run.workDir).create(recursive: true);
    try {
      task = _apply(task, DownloadStatus.resolvingMedia);
      run.plan = await _resolver.plan(run.sel, headers: run.sel.headers);
      // ready is the gate state between resolution and downloads.
      task = _apply(task, DownloadStatus.ready);
      await _runSteps(task, run);
    } on _MediaPaused {
      try {
        _parkPaused(task);
      } on InvalidTransitionError {
        final cur = _tasks[task.id.value] ?? task;
        if (!cur.status.isTerminal) {
          _fail(cur, ErrorCode.unknown, 'pause has no legal boundary');
        }
      }
    } catch (e) {
      final cur = _tasks[task.id.value] ?? task;
      if (!cur.status.isTerminal) {
        _fail(cur, ErrorCode.unknown, '$e');
      }
    }
  }

  /// Step loop — shared by the first run and every resume. Steps
  /// already produced are skipped via [run.stepIndex].
  Future<void> _runSteps(DownloadTask task, _MediaRun run) async {
    try {
      final sel = run.sel;
      final plan = run.plan!;
      for (; run.stepIndex < plan.steps.length; run.stepIndex++) {
        task = _tasks[task.id.value] ?? task;
        if (task.status.isTerminal) return;
        if (run.pauseRequested) throw _MediaPaused();
        final step = plan.steps[run.stepIndex];
        switch (step) {
          case EngineDownloadStep():
            final path = await _engineStep(task, step, run);
            task = _tasks[task.id.value]!;
            if (step.role == 'subtitle') {
              run.subtitles.add(path);
            } else {
              run.produced.add(path);
            }
          case ComponentDownloadStep():
            final path = await _componentStep(task, step, run);
            task = _tasks[task.id.value]!;
            run.produced.add(path);
          case MuxStep():
            task = _to(task, DownloadStatus.muxing);
            final r = await _muxer.mux(step, workDir: run.workDir);
            if (!r.ok) {
              _fail(task, ErrorCode.unknown, r.error ?? 'mux failed');
              return;
            }
            task = _tasks[task.id.value]!;
            if (r.outputPath != null) run.produced.add(r.outputPath!);
        }
      }

      // Subtitle stage — attach selected langs as files.
      if (sel.subtitleLangs.isNotEmpty && run.produced.isNotEmpty) {
        task = _to(task, DownloadStatus.subtitleProcessing);
        final video = run.produced.last;
        final r = await _muxer.attachSubtitles(video, run.subtitles);
        if (!r.ok) {
          _fail(task, ErrorCode.unknown, r.error ?? 'subtitle failed');
          return;
        }
        if (r.outputPath != null) run.produced.add(r.outputPath!);
        task = _tasks[task.id.value]!;
      }

      // Deliver the final artifact to the user's target directory.
      String? delivered;
      if (run.produced.isNotEmpty) {
        await Directory(task.output.targetDirectory)
            .create(recursive: true);
        final src = run.produced.last;
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
      _runs.remove(task.id.value);
      _bus.publish(DownloadCompleted(task.id, _clock().toUtc(),
          outputPath: delivered ??
              (run.produced.isEmpty ? null : run.produced.last)));
    } on _MediaPaused {
      // A status with no legal path to `paused` (e.g. a stage with no
      // remaining download boundary) must fail honestly — wedging the
      // task in a non-terminal state is worse.
      try {
        _parkPaused(task);
      } on InvalidTransitionError {
        final cur = _tasks[task.id.value] ?? task;
        if (!cur.status.isTerminal) {
          _fail(cur, ErrorCode.unknown, 'pause has no legal boundary');
        }
      }
    } catch (e) {
      final cur = _tasks[task.id.value] ?? task;
      if (!cur.status.isTerminal) {
        _fail(cur, ErrorCode.unknown, '$e');
      }
    }
  }

  /// pausing → paused with the run record retained for resume().
  void _parkPaused(DownloadTask task) {
    var cur = _tasks[task.id.value] ?? task;
    if (cur.status.isTerminal) return;
    cur = _to(cur, DownloadStatus.pausing);
    cur = _apply(cur, DownloadStatus.paused);
    _bus.publish(DownloadPaused(cur.id, _clock().toUtc()));
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

  Future<String> _engineStep(DownloadTask task,
      EngineDownloadStep step, _MediaRun run) async {
    task = _to(task, step.role == 'audio'
        ? DownloadStatus.downloadingAudio
        : DownloadStatus.downloadingVideo);
    final req = DownloadRequest(
      source: DownloadSource(initialUrl: step.url),
      output: OutputSpec(
          targetDirectory: run.workDir, fileName: step.outputFileName),
      headers: step.headers,
    );
    // enginePaused && isKnown → resume in place. enginePaused &&
    // !isKnown means the engine lost the task (host restart) —
    // fall back to create+start; on-disk segments still resume.
    final resuming = run.enginePaused && _engine.isKnown(task.id);
    run.enginePaused = false;
    if (!resuming) await _engine.create(task.id, req);
    final done = Completer<String>();
    final sub = _engine.events(task.id).listen((e) {
      if (e is EngineCompleted && !done.isCompleted) {
        done.complete(e.outputPath ??
            '${run.workDir}${Platform.pathSeparator}'
                '${step.outputFileName}');
      }
      if (e is EnginePaused && !done.isCompleted) {
        done.completeError(_MediaPaused());
      }
      if (e is EngineFailed && !done.isCompleted) {
        done.completeError(StateError(e.detail ?? e.error.name));
      }
    });
    run.engineStepActive = true;
    try {
      if (resuming) {
        await _engine.resume(task.id);
      } else {
        await _engine.start(task.id);
      }
      run.engineStarted = true;
      // A pause that landed during create/start couldn't reach the
      // engine — apply it now so the request isn't dropped.
      if (run.pauseRequested) {
        run.enginePaused = true;
        await _engine.pause(task.id);
      }
      return await done.future;
    } finally {
      run.engineStepActive = false;
      run.engineStarted = false;
      await sub.cancel();
    }
  }

  Future<String> _componentStep(DownloadTask task,
      ComponentDownloadStep step, _MediaRun run) async {
    task = _to(task, DownloadStatus.downloadingVideo);
    final dl = _downloaders[step.componentId];
    if (dl == null) {
      throw StateError(
          'no downloader registered for ${step.componentId}');
    }
    final path =
        '${run.workDir}${Platform.pathSeparator}${step.outputFileName}';
    final token = CancellationToken();
    run.stepCancel = token;
    final code = await dl.download(
        pageUrl: run.sel.pageUrl,
        outputPath: path,
        formatId: step.formatId,
        headers: run.sel.headers,
        subtitleLangs: run.sel.subtitleLangs,
        cancel: token);
    run.stepCancel = null;
    if (code == cancelledExitCode) throw _MediaPaused();
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
