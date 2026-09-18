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
    this.credentials,
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

  /// Mints headers:// refs for inbound request headers — the task
  /// record stores only the ref; values live in the resolver's
  /// process memory until dispatch (and every retry) resolves them.
  /// Without this, queue-mode downloads dropped the browser's
  /// cookies entirely and cookie-gated URLs stalled on silent 403s.
  final SessionCredentialResolver? credentials;
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
      // Dispatch concurrently: clients already order their own
      // dependent calls by awaiting each response, so serializing
      // here only lets a slow media.probe (yt-dlp, tens of seconds)
      // stall an unrelated pause/status behind it.
      // Errors are already mapped to wire responses inside
      // _dispatch; catchError guards the last unhandled path (a
      // _send throwing on a broken pipe) so wait()/unawaited stay
      // error-free.
      final d = _dispatch(msg).catchError((_) {});
      _inFlight.add(d);
      unawaited(d.whenComplete(() => _inFlight.remove(d)));
    }
    // stdin EOF: in-flight dispatches may still hold a pending
    // persistence write — drain them (bounded) so the caller's
    // flush below actually lands their state.
    try {
      await Future.wait(_inFlight).timeout(const Duration(seconds: 5));
    } catch (_) {}
    await _mediaSub?.cancel();
  }

  final _inFlight = <Future<void>>{};

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
    } on FormatException catch (e) {
      _sendError(req, RpcError.badRequest, '$e');
    } on TypeError catch (e) {
      // A missing/mistyped param throws TypeError at the `as` cast —
      // that's a malformed request, not an internal engine fault.
      _sendError(req, RpcError.badRequest, 'bad params: $e');
    } catch (e) {
      _sendError(req, RpcError.engineError, '$e');
    }
  }

  Future<Map<String, Object?>> _handle(RpcRequest req) async {
    String taskId() => req.params['taskId'] as String;

    DownloadRequest toDomain(DownloadRequestDto d) => DownloadRequest(
          source: DownloadSource(
            initialUrl: d.url,
            originalPageUrl: d.pageUrl,
            referer: d.referer,
            userAgent: d.userAgent,
            // Inline headers are transient by design — persist only
            // a ref; the scheduler resolves it back to the same map
            // at every dispatch/reattach inside this process.
            headersRef:
                d.headers.isEmpty ? null : credentials?.storeHeaders(d.headers),
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
        final st = scheduler?.task(id)?.status ??
            // Media tasks live in the coordinator — without this the
            // popup's liveness probe can't tell a stale 'resolving'
            // snapshot from a live task and paints it forever.
            media?.task(id)?.status;
        final detail = scheduler?.task(id)?.metadata['lastErrorDetail'] ??
            media?.task(id)?.metadata['lastErrorDetail'];
        return {
          'known': _created.contains(taskId()) ||
              scheduler?.task(id) != null ||
              media?.task(id) != null,
          if (st != null) 'status': st.name,
          if (detail != null) 'lastErrorDetail': detail,
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
        final p = await m.probe(req.params['pageUrl'] as String,
            headers: (req.params['headers'] as Map?)
                    ?.cast<String, String>() ??
                const {});
        return {
          'supported': p.supported,
          'title': p.title,
          'durationSeconds': p.durationSeconds,
          'webpageUrl': p.webpageUrl,
          'formats': [
            for (final f in p.formats)
              {
                'formatId': f.formatId,
                'ext': f.ext,
                'hasVideo': f.hasVideo,
                'hasAudio': f.hasAudio,
                'filesizeBytes': f.filesizeBytes,
                'bitrateKbps': f.bitrateKbps,
                'height': f.height,
                'width': f.width,
                'protocol': f.protocol,
                'label': f.label,
                'url': f.url,
              },
          ],
          'subtitles': [
            for (final s in p.subtitles)
              {'lang': s.lang, 'ext': s.ext},
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
          targetDirectory:
              req.params['targetDirectory'] is String
                  ? req.params['targetDirectory'] as String
                  : throw const FormatException(
                      'targetDirectory required'),
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

      case EngineProtocol.mediaRemove:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        await m.remove(TaskId(taskId()));
        return const {};

      case EngineProtocol.mediaList:
        final m = media;
        if (m == null) {
          throw UnsupportedError('media pipeline not configured');
        }
        return {
          'tasks': [
            for (final t in await m.tasks()) TaskCodec.encode(t)
          ],
        };

      case EngineProtocol.shutdown:
        _send(RpcResponse.ok(req.id, const {}).encode());
        // Flush the ack before the slow drain — exit() drops
        // buffered sink data, and the client's shutdown call has a
        // short timeout on this response.
        try {
          await _out.flush();
        } catch (_) {}
        for (final s in _eventSubs.values) {
          await s.cancel();
        }
        // Drain pending persistence — a transition that landed in
        // the final debounce/write-queue window must reach disk or
        // it resurrects on the next launch. Bounded: a wedged FS
        // must not hang shutdown.
        try {
          await scheduler?.flush()
              .timeout(const Duration(seconds: 5));
          await media?.flush().timeout(const Duration(seconds: 5));
        } catch (_) {}
        // Kill tracked children — an exit mid-download would
        // otherwise orphan yt-dlp/ffmpeg and they run forever.
        ChildProcessRegistry.killAll();
        try {
          await _out.flush();
        } catch (_) {}
        exit(0);
    }
    throw UnsupportedError('unknown method ${req.method}');
  }

  void _subscribe(String taskId) {
    _eventSubs[taskId]?.cancel();
    final s = scheduler;
    if (s != null) {
      // Unknown id (terminal record dropped by recover, removed, or
      // never created): error out instead of registering a changes
      // listener that can never match — the native host prunes its
      // replay set on this error.
      if (s.task(TaskId(taskId)) == null) {
        throw StateError('unknown task $taskId');
      }
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
            if (t.metadata['lastErrorDetail'] != null)
              'lastErrorDetail': t.metadata['lastErrorDetail'],
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
      final cur = s.task(TaskId(taskId))!;
      attachEngine();
      emitStatus(cur);
      if (cur.status.isTerminal) _eventSubs.remove(taskId)?.cancel();
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
