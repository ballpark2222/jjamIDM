import 'dart:async';
import 'dart:io';

import 'package:brisk_engine/brisk_engine.dart' as brisk;
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:path/path.dart' as p;

/// Per-task bookkeeping for the vendored Brisk engine.
final class _BriskTask {
  _BriskTask(this.item, this.settings, this.finalPath, this.tempDir,
      {StreamController<EngineEvent>? events})
      : events = events ?? StreamController<EngineEvent>.broadcast();

  final brisk.DownloadItemModel item;
  final brisk.DownloadSettings settings;

  /// Real output name — item.filePath carries the `.part` staging
  /// name while downloading; renamed on completion.
  final String finalPath;

  /// Per-task segment/temp dir — deleted when the task is cancelled.
  final Directory tempDir;

  /// Reused across create() re-attach (scheduler resume re-creates
  /// the task while subscribers stay attached to the same stream).
  final StreamController<EngineEvent> events;
  EngineProgress? lastProgress;

  /// Set once the engine isolate accepted the start command — the
  /// engine's per-task maps populate inside start(), so a pause,
  /// resume or cancel arriving earlier would crash on a null entry.
  var started = false;

  /// A pause requested before [started] — applied right after the
  /// engine task actually starts so the request isn't dropped.
  var wantPause = false;

  /// Set when the engine reports a paused status — clears on
  /// resume/start. Upstream drops pause commands that arrive before
  /// connection channels exist, so [BriskEngineAdapter._pauseUntilAcked]
  /// re-sends until this flag flips.
  var pauseAcked = false;

  /// A pause request is outstanding — set by pause()/the pre-start
  /// wantPause path, cleared by resume()/cancel(). Paused reports are
  /// per-connection: a straggler queued behind a resume can arrive
  /// after it, and must not emit EnginePaused (it would re-park a
  /// running task) or satisfy a newer pause's ack.
  var expectPaused = false;

  /// Bumped on every pause/resume/cancel — a [_pauseUntilAcked] loop
  /// still running from an older pause must stop re-sending, or it
  /// would re-pause a download the user just resumed.
  var pauseEpoch = 0;

  /// Pre-first-byte stall watchdog. Upstream never emits `failed`
  /// for a dead server: `_onError` leaves the connection status at
  /// `connecting`, and once the reset budget is spent nothing marks
  /// the download terminal — it would sit in the UI forever. Armed
  /// on start, disarmed on the first received byte (upstream's reset
  /// machinery owns mid-download stalls) or on pause/terminal.
  Timer? stallWatchdog;
}

/// DownloadEngine implementation over the vendored Brisk engine.
///
/// Brisk runs each download in its own isolate; this adapter only
/// translates FreeDM requests into Brisk items/settings and Brisk
/// progress messages into [EngineEvent]s. All Brisk types stay inside
/// this package (design doc §11).
final class BriskEngineAdapter implements DownloadEngine {
  BriskEngineAdapter({
    required Directory tempRoot,
    int defaultConnections = 8,
    int connectionRetryTimeoutMillis = 15000,
    int maxConnectionRetryCount = 20,
    bool engineLogging = false,
  })  : _tempRoot = tempRoot,
        _defaultConnections = defaultConnections,
        _retryTimeout = connectionRetryTimeoutMillis,
        _maxRetries = maxConnectionRetryCount,
        _engineLogging = engineLogging;

  /// Where per-task temp segment files live. Persisted across restarts
  /// so a new engine-host process can resume in-flight downloads.
  final Directory _tempRoot;
  final int _defaultConnections;
  final int _retryTimeout;
  final int _maxRetries;
  final bool _engineLogging;

  final _tasks = <String, _BriskTask>{};

  @override
  String get providerId => 'engine.brisk';

  @override
  int get apiVersion => 1;

  @override
  Future<EngineCapabilities> capabilities() async =>
      const EngineCapabilities(
        segmentedDownload: true,
        dynamicConnections: true,
        resume: true,
        customHeaders: true,
        cookies: true, // expressible via headers
        referer: true, // expressible via headers
        proxy: false,
        speedLimit: false, // engine has no limiter — see KNOWN_LIMITATIONS
        http2: false,
        ftp: false,
        torrent: false,
      );

  /// HEAD probe first (upstream requestFileInfo); when the server
  /// rejects HEAD entirely (some CDNs 404 it while GET works), fall
  /// back to a 1-byte range GET and read metadata off the response.
  Future<brisk.FileInfo?> _fileInfo(
      String url, Map<String, String> headers) async {
    try {
      final info = await brisk.HttpDownloadEngine
          .requestFileInfo(url, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (info != null && info.contentLength > 0) return info;
    } catch (_) {}
    return _rangeGetProbe(url, headers);
  }

  Future<brisk.FileInfo?> _rangeGetProbe(
      String url, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      req.headers.set('Range', 'bytes=0-0');
      final res =
          await req.close().timeout(const Duration(seconds: 15));
      // Headers are available now — do NOT drain the body: a server
      // that ignores Range replies 200 with the full file, and
      // draining would stream it all just to throw it away. The
      // force-close in `finally` aborts the unread body.
      if (res.statusCode != 200 && res.statusCode != 206) return null;

      var total = 0;
      if (res.statusCode == 206) {
        // Content-Range: bytes 0-0/<total>
        final cr = res.headers.value('content-range') ?? '';
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
        if (m != null) total = int.parse(m.group(1)!);
      } else {
        total = res.headers.contentLength; // Range ignored → full size
      }
      if (total <= 0) return null;

      final cd = res.headers.value('content-disposition');
      var name = _fileNameFromDisposition(cd) ??
          _fileNameFromUrl(res.redirects.isNotEmpty
              ? res.redirects.last.location.toString()
              : url);
      // CDN URLs often end in an extensionless token (xhs, signed
      // blobs) — without an extension the file won't open on
      // double-click. Infer one from Content-Type when missing.
      if (!name.contains('.')) {
        final ext =
            _extForContentType(res.headers.contentType?.mimeType);
        if (ext != null) name = '$name.$ext';
      }
      return brisk.FileInfo(
        res.statusCode == 206,
        name,
        total,
        res.redirects.isEmpty
            ? ''
            : res.redirects.last.location.toString(),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static const _contentTypeExt = {
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/x-matroska': 'mkv',
    'video/quicktime': 'mov',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/ogg': 'ogg',
    'audio/webm': 'weba',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'image/avif': 'avif',
    'application/pdf': 'pdf',
    'application/zip': 'zip',
    'application/x-7z-compressed': '7z',
    'application/x-rar-compressed': 'rar',
    'application/json': 'json',
    'text/plain': 'txt',
    'text/html': 'html',
  };

  static String? _extForContentType(String? mime) =>
      mime == null ? null : _contentTypeExt[mime.toLowerCase()];

  static String? _fileNameFromDisposition(String? cd) {
    if (cd == null) return null;
    final star =
        RegExp("""filename\\*=UTF-8''([^;]+)""").firstMatch(cd);
    if (star != null) {
      return Uri.decodeComponent(star.group(1)!.trim());
    }
    final q = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    return q?.group(1)?.trim();
  }

  @override
  Future<ProbeResult> probe(DownloadRequest request) async {
    try {
      final info = await _fileInfo(
        request.source.effectiveUrl,
        _mergedHeaders(request),
      );
      if (info == null) return const ProbeResult(supported: false);
      return ProbeResult(
        supported: true,
        fileName: info.fileName,
        totalBytes: info.contentLength,
        acceptsRanges: info.supportsPause,
        finalUrl: info.url.isEmpty ? null : info.url,
      );
    } catch (_) {
      return const ProbeResult(supported: false);
    }
  }

  @override
  Future<EngineTaskHandle> create(
      TaskId id, DownloadRequest request) async {
    final uid = id.value;
    final taskTemp = Directory(p.join(_tempRoot.path, uid));
    final merged = _mergedHeaders(request);

    // Brisk's engine sizes segments off item.fileSize — it must be
    // known up front (upstream populates it via buildDownloadItem's
    // HEAD probe). Probe here so the item is complete; a failed probe
    // still creates the task with size 0 and lets start() surface the
    // real error.
    brisk.FileInfo? info;
    try {
      info = await _fileInfo(
        request.source.effectiveUrl,
        merged,
      );
    } catch (_) {
      info = null;
    }

    final fileName = request.output.fileName ??
        (info != null && info.fileName.isNotEmpty ? info.fileName : null) ??
        _fileNameFromUrl(request.source.effectiveUrl);
    // Claim the final path up front — the `.part` staging name
    // derives from it, so two same-named tasks must diverge before
    // either starts writing, not just at the completion rename.
    // The re-attach case (same uid) keeps its original claim.
    final filePath = _claimUniqueTarget(
        p.join(request.output.targetDirectory, fileName), uid);

    final item = brisk.DownloadItemModel(
      uid: uid,
      fileName: fileName,
      // Download into a `.part` staging name; only completed files
      // get the real name — a bare filename in Downloads is never a
      // silently-truncated artifact.
      filePath: '$filePath.part',
      downloadUrl: request.source.effectiveUrl,
      progress: 0,
      fileSize: info?.contentLength ??
          request.output.expectedSize ??
          0,
      supportsPause: info?.supportsPause ?? false,
      headers: merged,
    );
    final settings = brisk.DownloadSettings(
      baseSaveDir: Directory(request.output.targetDirectory),
      totalConnections:
          request.maxConnections ?? _defaultConnections,
      baseTempDir: taskTemp,
      loggerEnabled: _engineLogging,
      connectionRetryTimeoutMillis: _retryTimeout,
      maxConnectionRetryCount: _maxRetries,
    );
    // Re-attach (scheduler resume / restart recovery) replaces the
    // task record but must keep the live event stream — subscribers
    // attached to the old controller would otherwise go silent.
    final prev = _tasks[uid];
    final task = _BriskTask(item, settings, filePath, taskTemp,
        events: prev != null && !prev.events.isClosed
            ? prev.events
            : null);
    _tasks[uid] = task;
    // A pause issued while create() was in flight lands here —
    // applied on start() like a pre-start pause.
    if (_preCreatePauses.remove(uid)) task.wantPause = true;
    return EngineTaskHandle(engineTaskId: uid);
  }

  /// Pauses requested before create() finished — the scheduler flips
  /// a task to `downloading` before engine.create returns, so pause
  /// can arrive while the task doesn't exist here yet. Queued and
  /// consumed by create() instead of throwing (a throw would wedge
  /// the scheduler task in `pausing`).
  final _preCreatePauses = <String>{};

  @override
  Future<void> start(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    await brisk.DownloadEngine.start(
      t.item,
      t.settings,
      onButtonAvailability: (_) {},
      onDownloadProgress: (msg) => _onProgress(id.value, msg),
    );
    if (!_tasks.containsKey(id.value)) {
      // cancel() ran while start was in flight and already emitted
      // the synthesized terminal event. Upstream rewrites commands
      // that arrive before connection channels exist into a start —
      // re-send cancel briefly so the just-started engine task
      // actually stops instead of running as an untracked zombie.
      for (var i = 0; i < 20; i++) {
        if (_tasks.containsKey(id.value)) {
          break; // re-created under the same uid — not our kill target
        }
        try {
          brisk.DownloadEngine.cancel(id.value);
        } catch (_) {
          break; // engine already dropped the uid
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return;
    }
    t.started = true;
    t.pauseAcked = false;
    _armStallWatchdog(id, t);
    if (t.wantPause) {
      t.wantPause = false;
      t.expectPaused = true;
      await _pauseUntilAcked(id, ++t.pauseEpoch);
    }
  }

  /// Arms the pre-first-byte watchdog — bound is the connection
  /// retry budget plus slack, clamped so a misconfigured engine
  /// can't hang or insta-fail a task.
  void _armStallWatchdog(TaskId id, _BriskTask t) {
    t.stallWatchdog?.cancel();
    final ms =
        (_retryTimeout * (_maxRetries + 2)).clamp(5000, 120000).toInt();
    t.stallWatchdog = Timer(Duration(milliseconds: ms),
        () => _onStallTimeout(id));
  }

  /// No bytes within the retry budget ⇒ the server is dead —
  /// upstream stalls in `connecting` forever, so fail the task here
  /// (engineUnavailable keeps it retryable through the scheduler).
  void _onStallTimeout(TaskId id) {
    final t = _tasks[id.value];
    if (t == null || !t.started) return;
    // Paused tasks are exempt — resume() re-arms the watchdog.
    if ((t.lastProgress?.receivedBytes ?? 0) > 0 || t.expectPaused) {
      return;
    }
    t.events.add(const EngineFailed(ErrorCode.engineUnavailable,
        detail: 'no response from server within the retry budget'));
    unawaited(t.events.close());
    _tasks.remove(id.value);
    try {
      brisk.DownloadEngine.cancel(id.value);
    } catch (_) {}
    _reapUpstream(id.value);
  }

  /// Sends pause until the engine acknowledges it with a paused
  /// status (bounded). Upstream drops — actually rewrites to a start
  /// command — any pause that arrives before connection channels are
  /// registered, and its pauseOnFinalHandshake deferral is dead code.
  /// The first progress message proves channels are live, so sends
  /// only start then (or after ~600ms for stalled servers). [epoch]
  /// abandons the loop when a newer pause/resume/cancel supersedes
  /// this request.
  Future<void> _pauseUntilAcked(TaskId id, int epoch) async {
    for (var i = 0; i < 60; i++) {
      final t = _tasks[id.value];
      if (t == null || t.pauseEpoch != epoch) return;
      if (t.pauseAcked) {
        // Settle beat before trusting the ack: paused reports are
        // per-connection, so a straggler from a previous cycle can
        // satisfy it while other connections still report running
        // progress (which un-acks in _onProgress). Give stragglers
        // one interval to contradict it; silence means the pause
        // is real.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (_tasks[id.value]?.pauseAcked ?? false) return;
        continue;
      }
      if (t.lastProgress != null || i > 3) {
        try {
          brisk.DownloadEngine.pause(id.value);
        } catch (_) {
          return; // engine forgot the uid — nothing left to pause
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  @override
  Future<void> pause(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) {
      _preCreatePauses.add(id.value);
      return;
    }
    if (!t.started) {
      t.wantPause = true;
      return;
    }
    // A stale ack from a previous pause cycle must not satisfy this
    // new request — clear it before the retry loop starts.
    t.pauseAcked = false;
    t.expectPaused = true;
    await _pauseUntilAcked(id, ++t.pauseEpoch);
  }

  @override
  Future<void> resume(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) {
      // A resume that beats create() cancels a queued pause.
      _preCreatePauses.remove(id.value);
      return;
    }
    t.pauseAcked = false;
    t.expectPaused = false;
    t.pauseEpoch++;
    if (!t.started) {
      t.wantPause = false;
      return;
    }
    // A stalled-out pause can outlive the watchdog — a resumed
    // download to a still-dead server must get a fresh budget.
    if ((t.lastProgress?.receivedBytes ?? 0) == 0) {
      _armStallWatchdog(id, t);
    }
    brisk.DownloadEngine.resume(id.value);
  }

  @override
  Future<void> cancel(TaskId id) async {
    final t = _tasks[id.value];
    _preCreatePauses.remove(id.value);
    if (t != null) {
      t.pauseEpoch++;
      t.expectPaused = false;
    }
    if (t == null) return;
    if (!t.started) {
      // Never reached the engine — synthesize the terminal event
      // and remove the artifacts the running path would have.
      try {
        File(t.item.filePath).deleteSync();
      } catch (_) {}
      try {
        t.tempDir.deleteSync(recursive: true);
      } catch (_) {}
      t.events.add(const EngineFailed(ErrorCode.cancelledByUser));
      unawaited(t.events.close());
      t.stallWatchdog?.cancel();
      _tasks.remove(id.value);
      return;
    }
    // Don't tear down the task here — the engine reports "Canceled"
    // as a progress status, and _onProgress closes the stream then.
    unawaited(_cancelUntilGone(id, t));
  }

  /// Re-sends cancel until the engine reports the task gone (bounded).
  /// Upstream rewrites a cancel that lands before connection channels
  /// exist into a start command — the same quirk [_pauseUntilAcked]
  /// covers for pause — so a single send can silently restart the
  /// download it meant to kill. The canceled status removes the
  /// [_tasks] entry, which ends the loop; the identity check stops it
  /// from cancelling a task re-created under the same id.
  Future<void> _cancelUntilGone(TaskId id, _BriskTask task) async {
    for (var i = 0; i < 40; i++) {
      if (!identical(_tasks[id.value], task)) return;
      try {
        brisk.DownloadEngine.cancel(id.value);
      } catch (_) {
        return; // engine forgot the uid — nothing left to cancel
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Engine checkpoints implicitly: segment progress lives in the
  /// task temp dir, so a new engine-host process re-creates the task
  /// with the same uid and continues from existing temp files.
  @override
  Future<void> checkpoint(TaskId id) async {}

  @override
  Future<void> replaceSource(
      TaskId id, DownloadRequest newRequest) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    t.item.downloadUrl = newRequest.source.effectiveUrl;
    t.item.headers = _mergedHeaders(newRequest);
    // Same-file validation is a domain responsibility and must happen
    // before this call — the engine itself does not compare files.
  }

  @override
  Future<void> setSpeedLimit(TaskId id, int? bytesPerSecond) {
    throw UnsupportedError(
        'brisk engine has no speed limiter; track a FreeDM throttle layer');
  }

  @override
  Stream<EngineEvent> events(TaskId id) {
    final t = _tasks[id.value];
    if (t == null) return const Stream.empty();
    return t.events.stream;
  }

  EngineProgress? lastProgress(TaskId id) => _tasks[id.value]?.lastProgress;

  /// Upstream never cleans its per-task statics: the engine isolate
  /// (with its periodic timers), stream channel and item entry leak
  /// for every download in a long-lived engine-host. Reap them on
  /// every terminal status — a retry runs create()+start() again
  /// which spawns a fresh isolate, and partial-file resume lives in
  /// the temp segment files, not the retained isolate.
  static void _reapUpstream(String uid) {
    try {
      brisk.DownloadEngine.engineIsolates.remove(uid)?.kill();
      brisk.DownloadEngine.engineChannels.remove(uid);
      brisk.DownloadEngine.downloadItems.remove(uid);
    } catch (_) {}
  }

  /// Whether the engine currently tracks [id] — events() returns an
  /// empty stream before create() runs, so queue-mode subscribers
  /// poll this before attaching.
  @override
  bool isKnown(TaskId id) => _tasks.containsKey(id.value);

  /// First `stem (N).ext` variant of [path] that isn't on disk and
  /// isn't already claimed by another live task. [excludeUid] keeps
  /// a re-attaching task from diverging off its own claim.
  String _claimUniqueTarget(String path, String excludeUid) {
    bool taken(String c) =>
        File(c).existsSync() ||
        _tasks.entries
            .any((e) => e.key != excludeUid && e.value.finalPath == c);
    if (!taken(path)) return path;
    final dir = p.dirname(path);
    final base = p.basename(path);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      final cand = p.join(dir, '$stem ($i)$ext');
      if (!taken(cand)) return cand;
    }
    return path;
  }

  /// First `stem (N).ext` variant of [path] that doesn't exist —
  /// the plain path when it's free. Keeps concurrent same-named
  /// downloads from clobbering each other's output.
  static String _uniqueTarget(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final base = p.basename(path);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      final cand = p.join(dir, '$stem ($i)$ext');
      if (!File(cand).existsSync()) return cand;
    }
    return path; // absurd — fall back to the plain name
  }

  // ------------------------------------------------------------------

  Map<String, String> _mergedHeaders(DownloadRequest request) {
    return {
      if (request.source.referer != null)
        'Referer': request.source.referer!,
      if (request.source.userAgent != null)
        'User-Agent': request.source.userAgent!,
      ...request.headers,
    };
  }

  String _fileNameFromUrl(String url) {
    final seg = Uri.parse(url).pathSegments;
    final last = seg.isEmpty ? '' : seg.last;
    return last.isEmpty ? 'download.bin' : Uri.decodeComponent(last);
  }

  void _onProgress(String uid, brisk.DownloadProgressMessage msg) {
    final t = _tasks[uid];
    if (t == null) return;
    final item = msg.downloadItem;
    final status = msg.status;

    if (msg.completionSignal ||
        status == brisk.DownloadStatus.assembleComplete) {
      // Promote the .part staging file to its final name — picking
      // `name (N).ext` when it's taken: deleting whatever sits at
      // the target would silently destroy an earlier download (or
      // any user file that happens to share the name).
      var outPath = item.filePath;
      try {
        final staging = File(outPath);
        if (staging.existsSync()) {
          final dest = _uniqueTarget(t.finalPath);
          staging.renameSync(dest);
          outPath = dest;
        }
      } catch (_) {}
      t.events
        ..add(EngineProgress(
          receivedBytes: item.fileSize,
          totalBytes: item.fileSize,
        ))
        ..add(EngineCompleted(outputPath: outPath));
      unawaited(t.events.close());
      t.stallWatchdog?.cancel();
      _tasks.remove(uid);
      _reapUpstream(uid);
      return;
    }
    if ((msg.paused || status == brisk.DownloadStatus.paused) &&
        t.expectPaused) {
      t.pauseAcked = true;
      t.events.add(const EnginePaused());
      return;
    }
    if (status == brisk.DownloadStatus.failed ||
        status == brisk.DownloadStatus.assembleFailed) {
      // Drop the visible .part artifact — it is never a valid file.
      // Temp segments stay so a retry/resume can continue.
      try {
        File(item.filePath).deleteSync();
      } catch (_) {}
      t.events.add(EngineFailed(ErrorCode.unknown,
          detail: msg.message.isEmpty ? status : msg.message));
      unawaited(t.events.close());
      t.stallWatchdog?.cancel();
      _tasks.remove(uid);
      // Safe to reap here too: a retry re-runs create()+start() with
      // a fresh item, and partial-file resume lives in the temp
      // segment files, not the retained isolate.
      _reapUpstream(uid);
      return;
    }
    if (status == brisk.DownloadStatus.canceled) {
      // Cancel = abandon: remove the .part artifact AND the temp
      // segments — nothing left to resume.
      try {
        File(item.filePath).deleteSync();
      } catch (_) {}
      try {
        t.tempDir.deleteSync(recursive: true);
      } catch (_) {}
      t.events.add(const EngineFailed(ErrorCode.cancelledByUser));
      unawaited(t.events.close());
      t.stallWatchdog?.cancel();
      _tasks.remove(uid);
      _reapUpstream(uid);
      return;
    }
    // The engine's aggregate message leaves totalReceivedBytes at 0;
    // per-connection byte counts live in connectionProgresses.
    final received = msg.connectionProgresses.fold<int>(
        0, (s, c) => s + c.totalReceivedBytes);
    final ev = EngineProgress(
      receivedBytes: received > 0
          ? received
          : (msg.totalDownloadProgress * item.fileSize).round(),
      totalBytes: item.fileSize > 0 ? item.fileSize : null,
      speedBytesPerSecond: msg.bytesTransferRate.round(),
      activeConnections: msg.connectionProgresses.length,
    );
    // Running progress contradicts a paused report — the ack was a
    // per-connection straggler and the pause hasn't actually landed;
    // clearing it lets the retry loop keep sending.
    if (t.expectPaused) t.pauseAcked = false;
    // First byte ⇒ the server is alive; upstream's reset machinery
    // owns stall recovery from here, so the watchdog stands down.
    if (ev.receivedBytes > 0) {
      t.stallWatchdog?.cancel();
      t.stallWatchdog = null;
    }
    t.lastProgress = ev;
    t.events.add(ev);
  }
}
