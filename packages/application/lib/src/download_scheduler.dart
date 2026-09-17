import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';

import 'credential_resolver.dart';
import 'speed_policy.dart';

/// Application-layer orchestrator (design doc §15): owns the queue,
/// concurrency slots, priority ordering, retry scheduling, speed-policy
/// plumbing, and restart recovery.
///
/// Every task mutation goes through [TaskStateMachine]; engines only
/// report [EngineEvent]s — they never set state.
final class DownloadScheduler {
  DownloadScheduler({
    required DownloadEngine engine,
    required TaskRepository repository,
    required EventBus eventBus,
    required TaskIdGenerator idGenerator,
    CredentialResolver credentials = const NullCredentialResolver(),
    this.maxConcurrent = 3,
    DateTime Function()? clock,
  })  : _engine = engine,
        _repo = repository,
        _bus = eventBus,
        _newId = idGenerator,
        _credentials = credentials,
        _clock = clock ?? DateTime.now;

  final DownloadEngine _engine;
  final TaskRepository _repo;
  final EventBus _bus;
  final TaskIdGenerator _newId;
  final CredentialResolver _credentials;
  final DateTime Function() _clock;

  /// Max simultaneous downloads.
  final int maxConcurrent;

  final _tasks = <String, DownloadTask>{};
  final _subs = <String, StreamSubscription<EngineEvent>>{};
  final _retryTimers = <String, Timer>{};
  final _persistDebounce = <String, Timer>{};
  final _taskLimits = <String, int?>{};
  final _changes = StreamController<DownloadTask>.broadcast();
  final _stateMachine = const TaskStateMachine();
  bool _disposed = false;

  void _emit(DownloadTask t) {
    if (!_disposed) _changes.add(t);
  }

  SpeedPolicy _speedPolicy = const SpeedPolicy();
  EngineCapabilities? _caps;

  SpeedPolicy get speedPolicy => _speedPolicy;

  /// Task updates for UI — emits the full task after every mutation.
  Stream<DownloadTask> get changes => _changes.stream;

  Future<EngineCapabilities> get capabilities async =>
      _caps ??= await _engine.capabilities();

  DownloadTask? task(TaskId id) => _tasks[id.value];

  Future<List<DownloadTask>> tasks({String? queueId}) =>
      _repo.list(queueId: queueId);

  /// Whether the engine can enforce limits itself. When false the
  /// policy is still recorded (a throttle layer may apply it later).
  Future<bool> get engineSupportsSpeedLimit async =>
      (await capabilities).speedLimit;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /// Restore persisted tasks after a process restart. Active engine
  /// state (segment temp files) lives outside this process, so a
  /// re-created engine task continues from partial bytes.
  Future<void> recover() async {
    for (final t in await _repo.listActive()) {
      _tasks[t.id.value] = t;
      switch (t.status) {
        case DownloadStatus.paused:
          // Engine task is re-created lazily on resume.
          break;
        case DownloadStatus.pausing:
          // Pause raced with shutdown — the engine is stopped now.
          _apply(t, DownloadStatus.paused);
          break;
        case DownloadStatus.verifying:
        case DownloadStatus.postProcessing:
        case DownloadStatus.muxing:
        case DownloadStatus.subtitleProcessing:
          _apply(t, DownloadStatus.failed,
              lastError: ErrorCode.unknown);
          break;
        case DownloadStatus.resolving:
        case DownloadStatus.resolvingMedia:
        case DownloadStatus.ready:
        case DownloadStatus.retryWait:
          unawaited(_resolveAndDispatch(t));
          break;
        case DownloadStatus.downloading:
        case DownloadStatus.downloadingVideo:
        case DownloadStatus.downloadingAudio:
          unawaited(_reattachRunning(t));
          break;
        default:
          break;
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs.values) {
      await s.cancel();
    }
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    for (final t in _persistDebounce.values) {
      t.cancel();
    }
    await _changes.close();
  }

  // ------------------------------------------------------------------
  // Queue operations
  // ------------------------------------------------------------------

  Future<DownloadTask> enqueue(
    DownloadRequest request, {
    int priority = 0,
    String? queueId,
    TaskKind kind = TaskKind.file,
    RetryPolicy retryPolicy = const RetryPolicy(),
    String? credentialRef,
    TaskId? id,
  }) async {
    final now = _clock().toUtc();
    final task = DownloadTask(
      id: id ?? _newId(),
      kind: kind,
      status: DownloadStatus.created,
      source: request.source,
      output: request.output,
      createdAt: now,
      updatedAt: now,
      priority: priority,
      queueId: queueId,
      providerId: _engine.providerId,
      retryPolicy: retryPolicy,
      credentialRef: credentialRef ?? request.source.credentialRef,
      metadata: {
        if (request.maxConnections != null)
          'maxConnections': '${request.maxConnections}',
      },
    );
    _tasks[task.id.value] = task;
    await _repo.upsert(task);
    _bus.publish(DownloadCreated(task.id, now));
    _emit(task);
    unawaited(_resolveAndDispatch(task));
    return task;
  }

  Future<void> pause(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    if (t.status != DownloadStatus.downloading &&
        t.status != DownloadStatus.downloadingVideo &&
        t.status != DownloadStatus.downloadingAudio) {
      return; // nothing in-flight to pause
    }
    _apply(t, DownloadStatus.pausing);
    await _engine.pause(id);
  }

  Future<void> resume(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    if (t.status == DownloadStatus.paused) {
      final resumed = _apply(t, DownloadStatus.downloading);
      _bus.publish(DownloadResumed(id, _clock().toUtc()));
      await _reattachRunning(resumed);
    }
  }

  Future<void> cancel(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    if (t.status.isTerminal) return;
    _retryTimers.remove(id.value)?.cancel();
    if (t.status.isActive || t.status == DownloadStatus.paused) {
      await _engine.cancel(id);
    }
    _apply(t, DownloadStatus.cancelled);
    await _subs.remove(id.value)?.cancel();
    _pump();
  }

  Future<void> remove(TaskId id) async {
    await cancel(id);
    _tasks.remove(id.value);
    await _repo.delete(id);
  }

  // ------------------------------------------------------------------
  // Speed policy
  // ------------------------------------------------------------------

  Future<void> setGlobalSpeedLimit(int? bytesPerSecond) async {
    _speedPolicy = bytesPerSecond == null
        ? _speedPolicy.copyWith(clearGlobal: true)
        : _speedPolicy.copyWith(globalBytesPerSecond: bytesPerSecond);
  }

  Future<void> setTaskSpeedLimit(TaskId id, int? bytesPerSecond) async {
    _taskLimits[id.value] = bytesPerSecond;
    if ((await capabilities).speedLimit) {
      await _engine.setSpeedLimit(id, bytesPerSecond);
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  Future<void> _resolveAndDispatch(DownloadTask task) async {
    task = _tasks[task.id.value] ?? task;
    if (task.status == DownloadStatus.created) {
      task = _apply(task, DownloadStatus.resolving);
    }
    if (task.status != DownloadStatus.resolving &&
        task.status != DownloadStatus.resolvingMedia) {
      _pump();
      return;
    }
    try {
      final probe = await _engine.probe(await _requestFor(task));
      if (probe.supported) {
        task = task.copyWith(
          source: task.source.copyWith(
            finalUrl: probe.finalUrl,
            contentLength: probe.totalBytes,
            contentType: probe.contentType,
          ),
          totalBytes: probe.totalBytes,
        );
        _tasks[task.id.value] = task;
      }
    } catch (_) {
      // probe is best-effort; the engine surfaces real errors at start
    }
    // Cancel may have landed while the probe was in flight.
    task = _tasks[task.id.value] ?? task;
    if (task.status != DownloadStatus.resolving &&
        task.status != DownloadStatus.resolvingMedia) {
      _pump();
      return;
    }
    task = _apply(task, DownloadStatus.ready);
    _bus.publish(DownloadResolved(task.id, _clock().toUtc(),
        finalUrl: task.source.finalUrl));
    await _repo.upsert(task);
    _pump();
  }

  /// Picks ready tasks by (priority desc, createdAt asc) while slots
  /// are free and dispatches them to the engine.
  void _pump() {
    final running = _tasks.values.where((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.downloadingVideo ||
        t.status == DownloadStatus.downloadingAudio ||
        t.status == DownloadStatus.pausing).length;
    var slots = maxConcurrent - running;
    if (slots <= 0) return;

    final ready = _tasks.values
        .where((t) => t.status == DownloadStatus.ready)
        .toList()
      ..sort((a, b) {
        final p = b.priority.compareTo(a.priority);
        return p != 0 ? p : a.createdAt.compareTo(b.createdAt);
      });
    for (final t in ready.take(slots)) {
      unawaited(_dispatch(t));
    }
  }

  Future<void> _dispatch(DownloadTask task) async {
    task = _tasks[task.id.value] ?? task;
    if (task.status != DownloadStatus.ready) return;
    final running = _apply(task, DownloadStatus.downloading);
    try {
      await _engine.create(running.id, await _requestFor(running));
      _subscribe(running.id);
      await _engine.start(running.id);
      _bus.publish(DownloadStarted(running.id, _clock().toUtc()));
    } catch (e) {
      _fail(running, ErrorCode.engineUnavailable, '$e');
    }
  }

  /// Re-attach an engine task that was already downloading — used by
  /// resume() and restart recovery.
  Future<void> _reattachRunning(DownloadTask task) async {
    try {
      await _engine.create(task.id, await _requestFor(task));
      _subscribe(task.id);
      await _engine.start(task.id);
    } catch (e) {
      _fail(task, ErrorCode.engineUnavailable, '$e');
    }
  }

  void _subscribe(TaskId id) {
    _subs[id.value]?.cancel();
    _subs[id.value] = _engine.events(id).listen(
      (e) => _onEngineEvent(id, e),
    );
  }

  Future<DownloadRequest> _requestFor(DownloadTask t) async {
    final headers = await _credentials.resolveHeaders(
      credentialRef: t.credentialRef ?? t.source.credentialRef,
      headersRef: t.source.headersRef,
    );
    return DownloadRequest(
      source: t.source,
      output: t.output,
      headers: headers,
      maxConnections:
          int.tryParse(t.metadata['maxConnections'] ?? ''),
      speedLimitBytesPerSecond: _taskLimits[t.id.value],
    );
  }

  void _onEngineEvent(TaskId id, EngineEvent e) {
    final t = _tasks[id.value];
    if (t == null || t.status.isTerminal) return;
    switch (e) {
      case EngineProgress():
        final updated = t.copyWith(
          receivedBytes: e.receivedBytes,
          totalBytes: e.totalBytes ?? t.totalBytes,
          updatedAt: _clock().toUtc(),
        );
        _tasks[id.value] = updated;
        _emit(updated);
        _persistDebounced(id);
      case EnginePaused():
        if (t.status == DownloadStatus.pausing ||
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.downloadingVideo ||
            t.status == DownloadStatus.downloadingAudio) {
          if (t.status != DownloadStatus.pausing) {
            _apply(t, DownloadStatus.pausing);
          }
          _apply(_tasks[id.value]!, DownloadStatus.paused);
          _bus.publish(DownloadPaused(id, _clock().toUtc()));
        }
      case EngineCompleted():
        unawaited(_complete(t, e));
      case EngineFailed():
        unawaited(_failed(t, e));
      case EngineResolved():
        final updated = t.copyWith(
          source: t.source.copyWith(
            finalUrl: e.finalUrl,
            etag: e.etag,
            lastModified: e.lastModified,
            contentLength: e.totalBytes,
            contentType: e.contentType,
          ),
          totalBytes: e.totalBytes ?? t.totalBytes,
        );
        _tasks[id.value] = updated;
        _emit(updated);
    }
  }

  Future<void> _complete(DownloadTask t, EngineCompleted e) async {
    // A completion can race with a pending pause — normalize through
    // downloading so the transition stays legal.
    if (t.status == DownloadStatus.pausing) {
      t = _apply(t, DownloadStatus.downloading);
    }
    if (t.status != DownloadStatus.downloading &&
        t.status != DownloadStatus.downloadingVideo &&
        t.status != DownloadStatus.downloadingAudio) {
      return;
    }
    t = _apply(t, DownloadStatus.verifying);
    final checksum = t.output.checksum;
    if (checksum != null && e.outputPath != null) {
      final ok = await _verifyChecksum(e.outputPath!, checksum);
      if (!ok) {
        _fail(t, ErrorCode.checksumMismatch,
            'checksum mismatch on ${e.outputPath}');
        return;
      }
    }
    _apply(t, DownloadStatus.completed,
        receivedBytes: t.totalBytes ?? t.receivedBytes);
    _bus.publish(
        DownloadCompleted(t.id, _clock().toUtc(), outputPath: e.outputPath));
    await _subs.remove(t.id.value)?.cancel();
    _pump();
  }

  Future<void> _failed(DownloadTask t, EngineFailed e) async {
    if (e.error == ErrorCode.cancelledByUser) {
      if (!t.status.isTerminal) {
        _apply(t, DownloadStatus.cancelled, lastError: e.error);
      }
      _pump();
      return;
    }
    // Paused tasks have no live engine work to retry — a failure here
    // is stale engine noise; keep the task paused for user resume.
    if (t.status == DownloadStatus.paused) return;
    // pausing→retryWait isn't a legal transition; normalize first.
    if (t.status == DownloadStatus.pausing) {
      t = _apply(t, DownloadStatus.downloading);
    }
    if (t.status != DownloadStatus.downloading &&
        t.status != DownloadStatus.downloadingVideo &&
        t.status != DownloadStatus.downloadingAudio) {
      _fail(t, e.error, e.detail ?? '');
      return;
    }
    final attempts = t.failedAttempts + 1;
    if (_isRetryable(e.error) && t.retryPolicy.canRetry(attempts)) {
      _apply(t, DownloadStatus.retryWait,
          failedAttempts: attempts, lastError: e.error);
      _bus.publish(DownloadRetryScheduled(t.id, _clock().toUtc(),
          attempt: attempts));
      _retryTimers[t.id.value] =
          Timer(t.retryPolicy.delayForAttempt(attempts), () {
        final cur = _tasks[t.id.value];
        if (cur == null || cur.status != DownloadStatus.retryWait) return;
        final ready = _apply(cur, DownloadStatus.downloading);
        unawaited(_reattachRunning(ready));
      });
      return;
    }
    _fail(t, e.error, e.detail ?? '');
  }

  bool _isRetryable(ErrorCode code) => switch (code) {
        ErrorCode.network ||
        ErrorCode.timeout ||
        ErrorCode.connectionDropped ||
        ErrorCode.httpServerError ||
        ErrorCode.engineUnavailable =>
          true,
        _ => false,
      };

  Future<bool> _verifyChecksum(String path, String spec) async {
    final sep = spec.indexOf(':');
    if (sep <= 0) return false;
    final algo = spec.substring(0, sep);
    final expected = spec.substring(sep + 1).toLowerCase();
    if (algo != 'sha256') return false;
    final digest =
        await sha256.bind(File(path).openRead()).first;
    return digest.toString() == expected;
  }

  void _fail(DownloadTask t, ErrorCode code, String detail) {
    _apply(t, DownloadStatus.failed, lastError: code);
    _bus.publish(
        DownloadFailed(t.id, _clock().toUtc(), error: code));
    unawaited(_subs.remove(t.id.value)?.cancel());
    _pump();
  }

  DownloadTask _apply(
    DownloadTask t,
    DownloadStatus to, {
    int? receivedBytes,
    int? failedAttempts,
    ErrorCode? lastError,
  }) {
    final updated = _stateMachine.transition(
      t,
      to,
      at: _clock().toUtc(),
      receivedBytes: receivedBytes,
      failedAttempts: failedAttempts,
      lastError: lastError,
    );
    _tasks[t.id.value] = updated;
    _emit(updated);
    unawaited(_repo.upsert(updated));
    return updated;
  }

  /// Progress events are high-frequency — write at most once per
  /// 500ms per task; transitions always persist immediately.
  void _persistDebounced(TaskId id) {
    _persistDebounce.putIfAbsent(
      id.value,
      () => Timer(const Duration(milliseconds: 500), () {
        _persistDebounce.remove(id.value);
        final t = _tasks[id.value];
        if (t != null) unawaited(_repo.upsert(t));
      }),
    );
  }
}
