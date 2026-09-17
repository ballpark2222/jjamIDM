import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_protocol/freedm_engine_protocol.dart';

/// Client side of DownloadEngine Protocol v1 — a [DownloadEngine]
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

  /// Spawn [argv] (e.g. `dart apps/engine-host/bin/main.dart`) and
  /// handshake the protocol version.
  static Future<EngineHostClient> spawn(List<String> argv,
      {Map<String, String>? environment}) async {
    final proc = await Process.start(argv.first, argv.sublist(1),
        environment: environment);
    final lines = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(RpcMessage.decodeLine)
        .where((m) => m != null)
        .cast<RpcMessage>()
        .asBroadcastStream();
    final client = EngineHostClient._(proc, lines).._listen();
    final hello = await client._call(EngineProtocol.hello);
    if (hello['protocol'] != EngineProtocol.version) {
      proc.kill();
      throw StateError(
          'engine protocol ${hello['protocol']} != ${EngineProtocol.version}');
    }
    return client;
  }

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
            }
          }
        }
      }
    });
  }

  Future<Map<String, Object?>> _call(String method,
      [Map<String, Object?> params = const {}]) {
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _proc.stdin.writeln(
        RpcRequest(id: id, method: method, params: params).encode());
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
  Future<void> cancel(TaskId id) async =>
      _call(EngineProtocol.taskCancel, {'taskId': id.value});
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

  @override
  Stream<EngineEvent> events(TaskId id) {
    final c = _taskEvents.putIfAbsent(
        id.value, () => StreamController<EngineEvent>());
    // Fire-and-forget subscribe so the host starts streaming.
    unawaited(_call(
        EngineProtocol.taskSubscribeEvents, {'taskId': id.value}));
    return c.stream;
  }

  EngineEvent? _eventFromJson(Map<String, Object?> p) {
    switch (p['type']) {
      case 'progress':
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
    _proc.kill();
  }
}
