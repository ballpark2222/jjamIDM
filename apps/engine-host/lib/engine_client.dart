import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_protocol/freedm_engine_protocol.dart';
import 'package:freedm_persistence/freedm_persistence.dart';

/// Client side of DownloadEngine Protocol — a [DownloadEngine]
/// backed by a spawned engine-host process speaking NDJSON-RPC.
///
/// Desktop/control-plane code talks to this; the engine bundle stays
/// a replaceable child process (design doc §4).
final class EngineHostClient implements DownloadEngine {
  EngineHostClient._(this._proc, this._lines);

  final Process _proc;
  final Stream<RpcMessage> _lines;

  var _nextId = 0;
  final _pending = <Object, Completer<Map<String, Object?>>>{};
  final _taskEvents =
      <String, StreamController<EngineEvent>>{};
  EngineCapabilities? _caps;

  /// Tasks this client believes the host still tracks — set on
  /// [create], cleared on terminal events and [cancel].
  final _known = <String>{};

  /// Spawn [argv] (e.g. `dart apps/engine-host/bin/main.dart`) and
  /// handshake the protocol version.
  static Future<EngineHostClient> spawn(List<String> argv,
      {Map<String, String>? environment}) async {
    final proc = await Process.start(argv.first, argv.sublist(1),
        environment: environment);
    // stderr must be drained or a chatty engine (logger enabled)
    // fills the pipe buffer and deadlocks the child process.
    unawaited(proc.stderr.drain<void>());
    final lines = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // A stray non-JSON stdout line (dependency print, partial
        // flush) must not error the stream — that would fire
        // _hostGone and kill the client over one bad frame.
        .map((l) {
          try {
            return RpcMessage.decodeLine(l);
          } catch (_) {
            return null;
          }
        })
        .where((m) => m != null)
        .cast<RpcMessage>()
        .asBroadcastStream();
    final client = EngineHostClient._(proc, lines).._listen();
    // A wedged or AV-blocked host never answers — bound the
    // handshake so spawn fails fast instead of hanging app boot.
    final hello = await client
        ._call(EngineProtocol.hello)
        .timeout(const Duration(seconds: 10));
    final v = (hello['protocol'] as num?)?.toInt();
    if (v == null || !EngineProtocol.supportedVersions.contains(v)) {
      proc.kill();
      throw StateError('engine protocol $v unsupported '
          '(client speaks ${EngineProtocol.supportedVersions})');
    }
    client._serverProtocol = v;
    return client;
  }

  /// Protocol version negotiated with the host (v1 lacks media.*).
  int get serverProtocol => _serverProtocol;
  int _serverProtocol = 1;
  bool get supportsMedia => _serverProtocol >= 2;

  /// Media task snapshots pushed by the host (TaskCodec-encoded).
  final _mediaTasks =
      StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get mediaTasks => _mediaTasks.stream;

  void _listen() {
    _lines.listen((msg) {
      if (msg is RpcResponse) {
        final c = _pending.remove(msg.id);
        if (c == null) return;
        if (msg.error != null) {
          c.completeError(
              StateError('${msg.error!.code}: ${msg.error!.message}'));
        } else {
          c.complete(msg.result ?? const {});
        }
      } else if (msg is RpcRequest && msg.id == null ||
          msg is RpcNotification) {
        // task.event notification (server → client)
        final m = msg is RpcNotification
            ? msg
            : RpcNotification(method: (msg as RpcRequest).method,
                params: msg.params);
        if (m.method == EngineProtocol.taskEvent) {
          final taskId = m.params['taskId'] as String?;
          final c = _taskEvents[taskId];
          final ev = _eventFromJson(m.params);
          if (taskId != null && c != null && ev != null) {
            c.add(ev);
            if (ev is EngineCompleted || ev is EngineFailed) {
              unawaited(c.close());
              _taskEvents.remove(taskId);
              _known.remove(taskId);
            }
          }
        } else if (m.method == EngineProtocol.mediaEvent) {
          final t = m.params['task'];
          if (t is Map && !_mediaTasks.isClosed) {
            _mediaTasks.add(
                TaskCodec.decode(t.cast<String, Object?>()));
          }
        }
      }
    }, onDone: _hostGone, onError: (_, __) => _hostGone());
  }

  /// The engine-host process exited or its stdout broke — fail every
  /// in-flight call (they would hang forever otherwise) and close
  /// per-task event streams so subscribers see a clean end.
  void _hostGone() {
    _dead = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('engine host exited'));
      }
    }
    _pending.clear();
    for (final c in _taskEvents.values) {
      unawaited(c.close());
    }
    _taskEvents.clear();
    _known.clear();
    if (!_mediaTasks.isClosed) unawaited(_mediaTasks.close());
  }

  /// Set once the host is gone — later [_call]s must fail fast
  /// instead of parking a completer in [_pending] that no response
  /// will ever complete (writes to a dead stdin error out
  /// asynchronously, leaving the future hanging).
  bool _dead = false;

  Future<Map<String, Object?>> _call(String method,
      [Map<String, Object?> params = const {}]) {
    if (_dead) {
      return Future.error(StateError('engine host exited'));
    }
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    try {
      _proc.stdin.writeln(
          RpcRequest(id: id, method: method, params: params).encode());
    } catch (e) {
      _pending.remove(id);
      c.completeError(StateError('engine host write failed: $e'));
    }
    return c.future;
  }

  Map<String, Object?> _requestJson(DownloadRequest r) =>
      DownloadRequestDto(
        url: r.source.effectiveUrl,
        targetDirectory: r.output.targetDirectory,
        fileName: r.output.fileName,
        headers: r.headers,
        referer: r.source.referer,
        userAgent: r.source.userAgent,
        maxConnections: r.maxConnections,
        speedLimitBytesPerSecond: r.speedLimitBytesPerSecond,
        pageUrl: r.source.originalPageUrl,
      ).toJson();

  @override
  String get providerId => 'engine.brisk';
  @override
  int get apiVersion => EngineProtocol.version;

  @override
  Future<EngineCapabilities> capabilities() async =>
      _caps ??= EngineCapabilities.fromJson(
          await _call(EngineProtocol.capabilities));

  @override
  Future<ProbeResult> probe(DownloadRequest request) async {
    final r = await _call(
        EngineProtocol.taskProbe, {'request': _requestJson(request)});
    return ProbeResult(
      supported: r['supported'] == true,
      fileName: r['fileName'] as String?,
      totalBytes: (r['totalBytes'] as num?)?.toInt(),
      acceptsRanges: r['acceptsRanges'] as bool?,
      finalUrl: r['finalUrl'] as String?,
      contentType: r['contentType'] as String?,
    );
  }

  @override
  Future<EngineTaskHandle> create(
      TaskId id, DownloadRequest request) async {
    final r = await _call(EngineProtocol.taskCreate,
        {'taskId': id.value, 'request': _requestJson(request)});
    _known.add(id.value);
    return EngineTaskHandle(
        engineTaskId: '${r['engineTaskId'] ?? id.value}');
  }

  @override
  Future<void> start(TaskId id) async =>
      _call(EngineProtocol.taskStart, {'taskId': id.value});
  @override
  Future<void> pause(TaskId id) async =>
      _call(EngineProtocol.taskPause, {'taskId': id.value});
  @override
  Future<void> resume(TaskId id) async =>
      _call(EngineProtocol.taskResume, {'taskId': id.value});
  @override
  Future<void> cancel(TaskId id) async {
    await _call(EngineProtocol.taskCancel, {'taskId': id.value});
    _known.remove(id.value);
  }

  /// Local view of whether the host still tracks [id] — tasks are
  /// marked on [create] and cleared on terminal events/[cancel].
  /// Queue-mode hosts may also park a task in `created` before any
  /// engine create; [status] reports that case remotely.
  @override
  bool isKnown(TaskId id) => _known.contains(id.value);
  @override
  Future<void> checkpoint(TaskId id) async =>
      _call(EngineProtocol.taskCheckpoint, {'taskId': id.value});
  @override
  Future<void> replaceSource(TaskId id, DownloadRequest r) async =>
      _call(EngineProtocol.taskReplaceSource,
          {'taskId': id.value, 'request': _requestJson(r)});
  @override
  Future<void> setSpeedLimit(TaskId id, int? bps) async =>
      _call(EngineProtocol.taskSetSpeedLimit,
          {'taskId': id.value, 'bytesPerSecond': bps});

  // ---- media pipeline (protocol v2) ----

  /// Probe a media page. Returns null when the host can't serve
  /// media (v1 host or missing tools).
  Future<Map<String, Object?>?> probeMedia(String pageUrl) async {
    if (!supportsMedia) return null;
    try {
      return await _call(
          EngineProtocol.mediaProbe, {'pageUrl': pageUrl});
    } on StateError {
      return null;
    }
  }

  /// Enqueue a media download; returns the new task id.
  Future<TaskId> enqueueMedia({
    required String pageUrl,
    required String targetDirectory,
    String? videoFormatId,
    String? audioFormatId,
    List<String> subtitleLangs = const [],
    String? outputFileName,
    Map<String, String> headers = const {},
  }) async {
    final r = await _call(EngineProtocol.mediaEnqueue, {
      'pageUrl': pageUrl,
      'targetDirectory': targetDirectory,
      if (videoFormatId != null) 'videoFormatId': videoFormatId,
      if (audioFormatId != null) 'audioFormatId': audioFormatId,
      'subtitleLangs': subtitleLangs,
      if (outputFileName != null) 'outputFileName': outputFileName,
      if (headers.isNotEmpty) 'headers': headers,
    });
    return TaskId('${r['taskId']}');
  }

  Future<void> cancelMedia(TaskId id) async =>
      _call(EngineProtocol.mediaCancel, {'taskId': id.value});

  Future<void> pauseMedia(TaskId id) async =>
      _call(EngineProtocol.mediaPause, {'taskId': id.value});

  Future<void> resumeMedia(TaskId id) async =>
      _call(EngineProtocol.mediaResume, {'taskId': id.value});

  /// Delete a media task's record on the host — cancels in-flight
  /// work first. Without this the record persisted in the media
  /// repo and resurfaced as failed on the next host start.
  Future<void> removeMedia(TaskId id) async =>
      _call(EngineProtocol.mediaRemove, {'taskId': id.value});

  /// Durable snapshot of every media task the host tracks —
  /// including tasks recovered to a terminal state before this
  /// client attached (media.event is broadcast-only; anything
  /// emitted before [mediaTasks] had a listener is only reachable
  /// through this pull). Soft-fails to an empty list on a v1 host,
  /// a media-less v2 host, a wedged host, or a malformed frame —
  /// the live event stream stays the source of truth.
  Future<List<DownloadTask>> listMediaTasks() async {
    if (!supportsMedia) return const [];
    try {
      final r = await _call(EngineProtocol.mediaList)
          .timeout(const Duration(seconds: 10));
      return [
        for (final t in (r['tasks'] as List? ?? const []))
          TaskCodec.decode((t as Map).cast<String, Object?>())
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Raw task.status result — `known` says whether the host still
  /// tracks the task; queue mode also reports the scheduler status.
  Future<Map<String, Object?>> status(TaskId id) async =>
      _call(EngineProtocol.taskStatus, {'taskId': id.value});

  @override
  Stream<EngineEvent> events(TaskId id) {
    if (_dead) return const Stream.empty();
    final c = _taskEvents.putIfAbsent(
        id.value, () => StreamController<EngineEvent>());
    // Fire-and-forget subscribe so the host starts streaming. The
    // error is swallowed — a dead host already closed this stream
    // via _hostGone, and a live-host RPC failure is reported to the
    // caller's other calls.
    unawaited(_call(
            EngineProtocol.taskSubscribeEvents, {'taskId': id.value})
        .catchError((_) => <String, Object?>{}));
    return c.stream;
  }

  EngineEvent? _eventFromJson(Map<String, Object?> p) {
    switch (p['type']) {
      case 'progress':
        // Queue-mode hosts synthesize status-carrying progress
        // frames — a terminal status must surface as the matching
        // terminal event or subscribers wait forever.
        switch ('${p['status']}') {
          case 'completed':
            return EngineCompleted(
                outputPath: p['outputPath'] as String?);
          case 'failed':
            return EngineFailed(
              ErrorCode.values.asNameMap()['${p['error']}'] ??
                  ErrorCode.unknown,
            );
          case 'cancelled':
            return const EngineFailed(ErrorCode.cancelledByUser);
          case 'paused':
            return const EnginePaused();
        }
        return EngineProgress(
          receivedBytes: (p['receivedBytes'] as num?)?.toInt() ?? 0,
          totalBytes: (p['totalBytes'] as num?)?.toInt(),
          speedBytesPerSecond:
              (p['speedBytesPerSecond'] as num?)?.toInt(),
          activeConnections:
              (p['activeConnections'] as num?)?.toInt(),
        );
      case 'resolved':
        return EngineResolved(
          fileName: p['fileName'] as String?,
          totalBytes: (p['totalBytes'] as num?)?.toInt(),
          acceptsRanges: p['acceptsRanges'] as bool?,
        );
      case 'paused':
        return const EnginePaused();
      case 'completed':
        return EngineCompleted(outputPath: p['outputPath'] as String?);
      case 'failed':
        return EngineFailed(
          ErrorCode.values.asNameMap()['${p['error']}'] ??
              ErrorCode.unknown,
          detail: p['detail'] as String?,
        );
    }
    return null;
  }

  Future<void> shutdown() async {
    try {
      await _call(EngineProtocol.shutdown)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    // The host acks before flushing persistence — force-killing
    // immediately could still land mid-write. Let it exit on its
    // own first; only a wedged process pays the kill. Bound must
    // exceed the server's worst-case drain (2 × 5s flushes).
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 12));
    } catch (_) {
      _proc.kill();
    }
  }
}
