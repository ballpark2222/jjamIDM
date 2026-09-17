import 'dart:async';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_engine_protocol/freedm_engine_protocol.dart';
import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:freedm_persistence/freedm_persistence.dart';

/// DownloadEngine Protocol v2 server — newline-delimited JSON-RPC on
/// stdin/stdout. This process is the Engine Bundle boundary: the
/// desktop control plane spawns it, speaks only this protocol, and can
/// swap the whole host as a versioned component.
///
/// Media pipeline (v2): when [media] is provided, media.probe /
/// media.enqueue / media.cancel are served and every media task
/// transition is pushed as a `media.event` notification carrying a
/// TaskCodec-encoded DownloadTask.
final class EngineHostServer {
  EngineHostServer({
    required this.engine,
    required Directory tempRoot,
    this.media,
    this.scheduler,
    IOSink? out,
  })  : _tempRoot = tempRoot,
        _out = out ?? stdout {
    _mediaSub = media?.changes.listen((t) {
      _send(RpcNotification(
        method: EngineProtocol.mediaEvent,
        params: {'task': TaskCodec.encode(t)},
      ).encode());
    });
  }

  final DownloadEngine engine;
  final MediaDownloadCoordinator? media;

  /// When set (browser-spawned hosts), task.* calls route through
  /// the application scheduler: queueing, concurrency, priority,
  /// retry policy and restart recovery apply instead of the raw
  /// create+start passthrough the desktop control plane uses.
  final DownloadScheduler? scheduler;
  final Directory _tempRoot;
  final IOSink _out;

  StreamSubscription<DownloadTask>? _mediaSub;
  final _eventSubs = <String, StreamSubscription<dynamic>>{};
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
    await _mediaSub?.cancel();
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

      case EngineProtocol.taskProbe:
        final dto = DownloadRequestDto.fromJson(
            (req.params['request'] as Map).cast<String, Object?>());
        final p = await engine.probe(toDomain(dto));
        return {
          'supported': p.supported,
          'fileName': p.fileName,
          'totalBytes': p.totalBytes,
          'acceptsRanges': p.acceptsRanges,
          'finalUrl': p.finalUrl,
          'contentType': p.contentType,
        };

      case EngineProtocol.taskCreate:
        final dto = DownloadRequestDto.fromJson(
            (req.params['request'] as Map).cast<String, Object?>());
        final id = TaskId(taskId());
        final s = scheduler;
        if (s != null) {
          // Queue mode: the task is persisted now and stays parked
          // until task.start — "download later" entries survive a
          // host restart via the repository.
          await s.enqueue(toDomain(dto),
              id: id,
              priority: (req.params['priority'] as num?)?.toInt() ?? 0,
              autoStart: false);
          _created.add(id.value);
          return {'engineTaskId': id.value};
        }
        final h = await engine.create(id, toDomain(dto));
        _created.add(taskId());
        return {'engineTaskId': h.engineTaskId};

      case EngineProtocol.taskStart:
        final id = TaskId(taskId());
        final s = scheduler;
        if (s != null) {
          await s.start(id);
          return const {};
        }
        await engine.start(id);
        return const {};

      case EngineProtocol.taskPause:
        final id = TaskId(taskId());
        final s = scheduler;
        if (s != null) {
          await s.pause(id);
          return const {};
        }
        await engine.pause(id);
        return const {};

      case EngineProtocol.taskResume:
        final id = TaskId(taskId());
        final s = scheduler;
        if (s != null) {
          // resume covers paused; a still-parked task wants start.
          final st = s.task(id)?.status;
          if (st == DownloadStatus.created ||
              st == DownloadStatus.ready) {
            await s.start(id);
          } else {
            await s.resume(id);
          }
          return const {};
        }
        await engine.resume(id);
        return const {};

      case EngineProtocol.taskCancel:
        final id = TaskId(taskId());
        final s = scheduler;
        if (s != null) {
          await s.cancel(id);
          return const {};
        }
        await engine.cancel(id);
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
        final id = TaskId(taskId());
        final p = engine is BriskEngineAdapter
            ? (engine as BriskEngineAdapter).lastProgress(id)
            : null;
        final st = scheduler?.task(id)?.status;
        return {
          'known': _created.contains(taskId()) ||
              scheduler?.task(id) != null,
          if (st != null) 'status': st.name,
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

      case EngineProtocol.mediaProbe:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        final p = await m.probe(req.params['pageUrl'] as String);
        return {
          'supported': p.supported,
          'title': p.title,
          'formats': [
            for (final f in p.formats)
              {
                'formatId': f.formatId,
                'ext': f.ext,
                'hasVideo': f.hasVideo,
                'hasAudio': f.hasAudio,
                'filesizeBytes': f.filesizeBytes,
                'height': f.height,
              },
          ],
        };

      case EngineProtocol.mediaEnqueue:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        final t = await m.enqueueMedia(
          MediaSelection(
            pageUrl: req.params['pageUrl'] as String,
            videoFormatId: req.params['videoFormatId'] as String?,
            audioFormatId: req.params['audioFormatId'] as String?,
            subtitleLangs:
                (req.params['subtitleLangs'] as List?)?.cast<String>() ??
                    const [],
            outputFileName: req.params['outputFileName'] as String?,
            headers: (req.params['headers'] as Map?)
                    ?.cast<String, String>() ??
                const {},
          ),
          workDir: req.params['workDir'] as String? ??
              '${_tempRoot.path}${Platform.pathSeparator}media',
          targetDirectory: req.params['targetDirectory'] as String,
        );
        return {'taskId': t.id.value};

      case EngineProtocol.mediaCancel:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        await m.cancel(TaskId(taskId()));
        return const {};

      case EngineProtocol.mediaPause:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        await m.pause(TaskId(taskId()));
        return const {};

      case EngineProtocol.mediaResume:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        await m.resume(TaskId(taskId()));
        return const {};

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
    final s = scheduler;
    if (s != null) {
      // Queue mode: engine.create may not have run yet (task parked
      // or waiting for a slot), so a raw engine.events() here would
      // be empty forever. Scheduler task changes carry status+bytes;
      // raw engine events get attached once the task dispatches.
      StreamSubscription<EngineEvent>? engSub;
      void attachEngine() {
        if (engSub != null) return;
        // The scheduler flips status to `downloading` BEFORE calling
        // engine.create — subscribing then yields an empty stream.
        // Retry on the next active emission (progress/transition)
        // once the engine actually knows the task.
        if (!engine.isKnown(TaskId(taskId))) return;
        engSub = engine.events(TaskId(taskId)).listen((e) {
          _send(RpcNotification(
            method: EngineProtocol.taskEvent,
            params: {'taskId': taskId, ..._eventJson(e)},
          ).encode());
        });
      }
      void emitStatus(DownloadTask t) {
        // Best-effort output path so a completed notification still
        // gets open/reveal buttons even if the raw engine event
        // loses the race against this status record.
        String? outPath;
        if (t.status == DownloadStatus.completed) {
          // The scheduler records the engine's real path; fall back
          // to a guess only for tasks completed before that existed.
          outPath = t.metadata['outputPath'];
          if (outPath == null) {
            final name = t.output.fileName ??
                (t.source.finalUrl ?? t.source.initialUrl)
                    .split('/')
                    .last;
            if (name.isNotEmpty) {
              outPath = '${t.output.targetDirectory}'
                  '${Platform.pathSeparator}$name';
            }
          }
        }
        _send(RpcNotification(
          method: EngineProtocol.taskEvent,
          params: {
            'taskId': taskId,
            'type': 'progress',
            'status': t.status.name,
            'receivedBytes': t.receivedBytes,
            'totalBytes': t.totalBytes,
            if (outPath != null) 'outputPath': outPath,
            if (t.lastError != ErrorCode.none)
              'error': t.lastError.name,
          },
        ).encode());
      }
      _eventSubs[taskId] = s.changes.listen((t) {
        if (t.id.value != taskId) return;
        // Retry on EVERY change until attached — the engine-side
        // 'completed' event carries the real outputPath (probe-
        // derived names/extensions differ from the synthesized
        // fallback), and a fast download can finish between the
        // 'downloading' emission and the next scheduler change.
        attachEngine();
        emitStatus(t);
        if (t.status.isTerminal) {
          engSub?.cancel();
          _eventSubs.remove(taskId)?.cancel();
        }
      });
      final cur = s.task(TaskId(taskId));
      if (cur != null) {
        attachEngine();
        emitStatus(cur);
        if (cur.status.isTerminal) _eventSubs.remove(taskId)?.cancel();
      }
      return;
    }
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
