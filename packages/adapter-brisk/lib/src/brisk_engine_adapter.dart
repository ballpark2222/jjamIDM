import 'dart:async';
import 'dart:io';

import 'package:brisk_engine/brisk_engine.dart' as brisk;
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:path/path.dart' as p;

/// Per-task bookkeeping for the vendored Brisk engine.
final class _BriskTask {
  _BriskTask(this.item, this.settings);

  final brisk.DownloadItemModel item;
  final brisk.DownloadSettings settings;
  final events = StreamController<EngineEvent>.broadcast();
  EngineProgress? lastProgress;
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
      await res.drain<void>();
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
      client.close();
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
    final filePath =
        p.join(request.output.targetDirectory, fileName);

    final item = brisk.DownloadItemModel(
      uid: uid,
      fileName: fileName,
      filePath: filePath,
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
    _tasks[uid] = _BriskTask(item, settings);
    return EngineTaskHandle(engineTaskId: uid);
  }

  @override
  Future<void> start(TaskId id) async {
    final t = _tasks[id.value];
    if (t == null) throw StateError('unknown task ${id.value}');
    brisk.DownloadEngine.start(
      t.item,
      t.settings,
      onButtonAvailability: (_) {},
      onDownloadProgress: (msg) => _onProgress(id.value, msg),
    );
  }

  @override
  Future<void> pause(TaskId id) async =>
      brisk.DownloadEngine.pause(id.value);

  @override
  Future<void> resume(TaskId id) async =>
      brisk.DownloadEngine.resume(id.value);

  @override
  Future<void> cancel(TaskId id) async {
    // Don't tear down the task here — the engine reports "Canceled"
    // as a progress status, and _onProgress closes the stream then.
    brisk.DownloadEngine.cancel(id.value);
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
      t.events
        ..add(EngineProgress(
          receivedBytes: item.fileSize,
          totalBytes: item.fileSize,
        ))
        ..add(EngineCompleted(outputPath: item.filePath));
      unawaited(t.events.close());
      _tasks.remove(uid);
      return;
    }
    if (msg.paused || status == brisk.DownloadStatus.paused) {
      t.events.add(const EnginePaused());
      return;
    }
    if (status == brisk.DownloadStatus.failed ||
        status == brisk.DownloadStatus.assembleFailed) {
      t.events.add(EngineFailed(ErrorCode.unknown,
          detail: msg.message.isEmpty ? status : msg.message));
      unawaited(t.events.close());
      _tasks.remove(uid);
      return;
    }
    if (status == brisk.DownloadStatus.canceled) {
      t.events.add(const EngineFailed(ErrorCode.cancelledByUser));
      unawaited(t.events.close());
      _tasks.remove(uid);
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
    t.lastProgress = ev;
    t.events.add(ev);
  }
}
