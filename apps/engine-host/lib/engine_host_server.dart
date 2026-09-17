import 'dart:async';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_protocol/freedm_engine_protocol.dart';

/// DownloadEngine Protocol v1 server — newline-delimited JSON-RPC on
/// stdin/stdout. This process is the Engine Bundle boundary: the
/// desktop control plane spawns it, speaks only this protocol, and can
/// swap the whole host as a versioned component.
final class EngineHostServer {
  EngineHostServer({
    required this.engine,
    required Directory tempRoot,
    IOSink? out,
  })  : _tempRoot = tempRoot,
        _out = out ?? stdout;

  final DownloadEngine engine;
  final Directory _tempRoot;
  final IOSink _out;

  final _eventSubs = <String, StreamSubscription<EngineEvent>>{};
  final _created = <String>{}; // taskIds known to this host

  Future<void> run(Stream<String> lines) async {
    await for (final line in lines) {
      RpcMessage? msg;
      try {
        msg = RpcMessage.decodeLine(line);
      } on FormatException {
        continue; // ignore garbage on the wire
      }
      if (msg is! RpcRequest) continue;
      await _dispatch(msg);
    }
  }

  Future<void> _dispatch(RpcRequest req) async {
    try {
      final result = await _handle(req);
      if (req.id != null) {
        _send(RpcResponse.ok(req.id, result).encode());
      }
    } on UnsupportedError catch (e) {
      _sendError(req, RpcError.unsupported, '$e');
    } on StateError catch (e) {
      _sendError(req, RpcError.taskNotFound, e.message);
    } catch (e) {
      _sendError(req, RpcError.engineError, '$e');
    }
  }

  Future<Map<String, Object?>> _handle(RpcRequest req) async {
    String taskId() => req.params['taskId'] as String;

    DownloadRequest toDomain(DownloadRequestDto d) => DownloadRequest(
          source: DownloadSource(
            initialUrl: d.url,
            referer: d.referer,
            userAgent: d.userAgent,
          ),
          output: OutputSpec(
            targetDirectory: d.targetDirectory,
            fileName: d.fileName,
          ),
          headers: d.headers,
          maxConnections: d.maxConnections,
          speedLimitBytesPerSecond: d.speedLimitBytesPerSecond,
        );

    switch (req.method) {
      case EngineProtocol.hello:
        final caps = await engine.capabilities();
        return EngineHello(
          protocol: EngineProtocol.version,
          bundleId: engine.providerId,
          bundleVersion: 'dev',
          engineName: 'Brisk',
          engineRevision:
              'ec9e4f10ac1498e1ed9d6128276277641636b392',
          stateSchema: 1,
          capabilities: caps.toJson(),
        ).toJson();

      case EngineProtocol.capabilities:
        return (await engine.capabilities()).toJson();

      case EngineProtocol.taskCreate:
        final dto = DownloadRequestDto.fromJson(
            (req.params['request'] as Map).cast<String, Object?>());
        final h = await engine.create(TaskId(taskId()), toDomain(dto));
        _created.add(taskId());
        return {'engineTaskId': h.engineTaskId};

      case EngineProtocol.taskStart:
        await engine.start(TaskId(taskId()));
        return const {};

      case EngineProtocol.taskPause:
        await engine.pause(TaskId(taskId()));
        return const {};

      case EngineProtocol.taskResume:
        await engine.resume(TaskId(taskId()));
        return const {};

      case EngineProtocol.taskCancel:
        await engine.cancel(TaskId(taskId()));
        return const {};

      case EngineProtocol.taskCheckpoint:
        await engine.checkpoint(TaskId(taskId()));
        return const {};

      case EngineProtocol.taskReplaceSource:
        final dto = DownloadRequestDto.fromJson(
            (req.params['request'] as Map).cast<String, Object?>());
        await engine.replaceSource(TaskId(taskId()), toDomain(dto));
        return const {};

      case EngineProtocol.taskSetSpeedLimit:
        await engine.setSpeedLimit(
            TaskId(taskId()), req.params['bytesPerSecond'] as int?);
        return const {};

      case EngineProtocol.taskStatus:
        final p = engine is BriskEngineAdapter
            ? (engine as BriskEngineAdapter)
                .lastProgress(TaskId(taskId()))
            : null;
        return {
          'known': _created.contains(taskId()),
          if (p != null) 'receivedBytes': p.receivedBytes,
          if (p?.totalBytes != null) 'totalBytes': p!.totalBytes,
          if (p?.speedBytesPerSecond != null)
            'speedBytesPerSecond': p!.speedBytesPerSecond,
        };

      case EngineProtocol.taskSubscribeEvents:
        _subscribe(taskId());
        return const {};

      case EngineProtocol.selfTest:
        await _tempRoot.create(recursive: true);
        final probe = File(
            '${_tempRoot.path}${Platform.pathSeparator}.selftest');
        await probe.writeAsString('ok');
        await probe.delete();
        return const {'ok': true};

      case EngineProtocol.shutdown:
        _send(RpcResponse.ok(req.id, const {}).encode());
        for (final s in _eventSubs.values) {
          await s.cancel();
        }
        exit(0);
    }
    throw UnsupportedError('unknown method ${req.method}');
  }

  void _subscribe(String taskId) {
    _eventSubs[taskId]?.cancel();
    _eventSubs[taskId] =
        engine.events(TaskId(taskId)).listen((e) {
      _send(RpcNotification(
        method: EngineProtocol.taskEvent,
        params: {
          'taskId': taskId,
          ..._eventJson(e),
        },
      ).encode());
      if (e is EngineCompleted || e is EngineFailed) {
        _eventSubs.remove(taskId)?.cancel();
      }
    });
  }

  Map<String, Object?> _eventJson(EngineEvent e) => switch (e) {
        EngineProgress() => {
            'type': 'progress',
            'receivedBytes': e.receivedBytes,
            'totalBytes': e.totalBytes,
            'speedBytesPerSecond': e.speedBytesPerSecond,
            'activeConnections': e.activeConnections,
          },
        EngineResolved() => {
            'type': 'resolved',
            'fileName': e.fileName,
            'totalBytes': e.totalBytes,
            'acceptsRanges': e.acceptsRanges,
          },
        EnginePaused() => {'type': 'paused'},
        EngineCompleted() =>
          {'type': 'completed', 'outputPath': e.outputPath},
        EngineFailed() => {
            'type': 'failed',
            'error': e.error.name,
            'detail': e.detail,
          },
      };

  void _send(String line) {
    _out.writeln(line);
  }

  void _sendError(RpcRequest req, int code, String message) {
    if (req.id == null) return;
    _send(RpcResponse.err(req.id, RpcError(code, message)).encode());
  }
}
