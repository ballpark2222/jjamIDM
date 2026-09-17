import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Deterministic local fixture server (design doc §33, prompt M2).
/// Every endpoint is reproducible — file content derives from a seed so
/// tests can assert SHA-256 without storing blobs.
final class FixtureServer {
  FixtureServer._(this._server);

  final HttpServer _server;

  /// Latest valid token for /file-expired-url; bumped by /issue.
  int _token = 0;

  /// Remaining mid-body drops for /file-drop-connection.
  int _dropBudget = 3;

  /// Deterministic payload byte at absolute position [i].
  /// Position-stable: a Range slice always matches the corresponding
  /// slice of the virtual file, so hash checks work across segments.
  static int fixtureByteAt(int i, {int seed = 7}) =>
      (i * seed + i) & 0xFF;

  /// Bytes of the virtual file at absolute range [start, start+length).
  static List<int> fixtureRange(int start, int length, {int seed = 7}) =>
      List<int>.generate(length, (j) => fixtureByteAt(start + j, seed: seed));

  /// Convenience: full virtual file content.
  static List<int> fixtureBytes(int length, {int seed = 7}) =>
      fixtureRange(0, length, seed: seed);

  static const int defaultLength = 1 << 20; // 1 MiB

  static Future<FixtureServer> start({int port = 0}) async {
    final s = FixtureServer._(await HttpServer.bind(
        InternetAddress.loopbackIPv4, port));
    // Socket write errors are expected from the drop fixtures —
    // swallow them so they don't surface as unhandled async errors.
    s._server.listen(s._handle, onError: (_) {});
    return s;
  }

  int get port => _server.port;
  String get base => 'http://127.0.0.1:$port';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/file':
          return await _serveFile(req, length: defaultLength);
        case '/file-range':
          return await _serveFile(req,
              length: defaultLength, ranges: true);
        case '/file-no-range':
          return await _serveFile(req,
              length: defaultLength, ranges: false);
        case '/file-slow':
          final len = int.tryParse(
                  req.uri.queryParameters['length'] ?? '') ??
              defaultLength;
          final delay = int.tryParse(
                  req.uri.queryParameters['delay'] ?? '') ??
              20;
          return await _serveFile(req,
              length: len, ranges: true, chunkDelay: delay);
        case '/file-drop-connection':
          // The first N GET requests die mid-body; retries succeed —
          // models a flaky connection that recovers. HEAD/probe
          // requests always pass (a flaky data path, not flaky server).
          if (req.method == 'GET' && _dropBudget > 0) {
            _dropBudget--;
            return await _drop(req, at: defaultLength ~/ 2);
          }
          return await _serveFile(req,
              length: defaultLength, ranges: true);
        case '/file-hang':
          // Sends one chunk then holds the connection open forever —
          // used to prove cancel works mid-flight.
          res.headers.contentType =
              ContentType('application', 'octet-stream');
          res.contentLength = defaultLength;
          res.add(fixtureBytes(64 * 1024));
          await res.flush();
          return await Completer<void>().future; // never completes
        case '/file-random-disconnect':
          return await _drop(
              req, at: Random().nextInt(defaultLength - 1) + 1);
        case '/file-auth-cookie':
          if (req.headers.value('cookie')?.contains('session=fixture') ==
              true) {
            return await _serveFile(req,
                length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.unauthorized);
        case '/file-auth-header':
          if (req.headers.value('authorization') == 'Bearer fixture-token') {
            return await _serveFile(req,
                length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.unauthorized);
        case '/file-auth-referer':
          final ref = req.headers.value('referer') ?? '';
          if (ref.startsWith(base)) {
            return await _serveFile(req,
                length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.forbidden);
        case '/file-redirect':
          res.statusCode = HttpStatus.found;
          res.headers.set('location', '/file-range');
          return await res.close();
        case '/issue':
          _token++;
          res.headers.contentType = ContentType.text;
          res.write('/file-expired-url?token=$_token');
          return await res.close();
        case '/file-expired-url':
          final tok = int.tryParse(req.uri.queryParameters['token'] ?? '');
          if (tok != null && tok == _token) {
            return await _serveFile(req,
                length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.forbidden);
        case '/file-head-rejected':
          // Some CDNs 404 HEAD entirely while GET/Range work fine.
          if (req.method == 'HEAD') {
            return _deny(res, HttpStatus.notFound);
          }
          return await _serveFile(req,
              length: defaultLength, ranges: true);
        case '/file-video-noext':
          // Signed-CDN shape: HEAD rejected, extensionless URL token,
          // real type only in Content-Type.
          if (req.method == 'HEAD') {
            return _deny(res, HttpStatus.notFound);
          }
          return await _serveFile(req,
              length: defaultLength,
              ranges: true,
              contentType: ContentType('video', 'mp4'));
        case '/file-changing-etag':
          return await _serveFile(req,
              length: defaultLength,
              ranges: true,
              etag: '"${Random().nextInt(1 << 31)}"');
        case '/file-changing-length':
          return await _serveFile(req,
              length: defaultLength + Random().nextInt(4096),
              ranges: true);
        case '/hls/master.m3u8':
          return await _hls(res);
        case '/dash/manifest.mpd':
          return await _dash(res);
        default:
          if (req.uri.path.startsWith('/hls/seg')) {
            return await _serveFile(req, length: 64 * 1024, seed: 11);
          }
          if (req.uri.path.startsWith('/dash/seg')) {
            return await _serveFile(req, length: 64 * 1024, seed: 13);
          }
          res.statusCode = HttpStatus.notFound;
          return await res.close();
      }
    } catch (_) {
      // client went away mid-stream — fine for drop fixtures
    }
  }

  void _deny(HttpResponse res, int code) {
    res.statusCode = code;
    res.close();
  }

  Future<void> _serveFile(
    HttpRequest req, {
    required int length,
    int seed = 7,
    bool ranges = false,
    int chunkDelay = 0,
    String? etag,
    ContentType? contentType,
  }) async {
    final res = req.response;
    res.headers.set('etag', etag ?? '"fixture-$seed-$length"');
    res.headers.set('last-modified', 'Thu, 01 Jan 2026 00:00:00 GMT');
    res.headers.set('accept-ranges', ranges ? 'bytes' : 'none');
    res.headers.contentType =
        contentType ?? ContentType('application', 'octet-stream');

    var start = 0;
    var end = length - 1;
    final range = req.headers.value('range');
    if (ranges && range != null) {
      final m =
          RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        if (start >= length) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set('content-range', 'bytes */$length');
          return res.close();
        }
        end = min(end, length - 1);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set('content-range', 'bytes $start-$end/$length');
      }
    }

    final bodyLen = end - start + 1;
    res.contentLength = bodyLen;
    if (req.method == 'HEAD') return res.close();

    const chunk = 64 * 1024;
    var off = start;
    while (off <= end) {
      final n = min(chunk, end - off + 1);
      res.add(fixtureRange(off, n, seed: seed));
      if (chunkDelay > 0) {
        await res.flush();
        await Future<void>.delayed(Duration(milliseconds: chunkDelay));
      }
      off += n;
    }
    return res.close();
  }

  /// Detaches the socket and writes a valid but truncated response:
  /// honors Range like [_serveFile] (206 + Content-Range), announces the
  /// full requested body via Content-Length, sends only part of it, then
  /// destroys the connection — the client sees a mid-body drop whose
  /// prefix bytes are still position-correct for its segment.
  Future<void> _drop(HttpRequest req, {required int at}) async {
    final res = req.response;
    res.headers.set('etag', '"fixture-7-$defaultLength"');
    res.headers.set('accept-ranges', 'bytes');
    res.headers.contentType =
        ContentType('application', 'octet-stream');

    var start = 0;
    var end = defaultLength - 1;
    final range = req.headers.value('range');
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        end = min(end, defaultLength - 1);
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set('content-range', 'bytes $start-$end/$defaultLength');
      }
    }

    final bodyLen = end - start + 1;
    res.contentLength = bodyLen;
    final socket = await res.detachSocket();
    // Swallow socket-level errors — the client may already be gone,
    // and unhandled async errors would trip the test runner.
    unawaited(socket.done.catchError((_) => null));
    socket.add(fixtureRange(start, min(at, bodyLen ~/ 2)));
    try {
      await socket.flush();
    } catch (_) {}
    socket.destroy();
  }

  Future<void> _hls(HttpResponse res) {
    res.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    res.write('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
''');
    return res.close();
  }

  Future<void> _dash(HttpResponse res) {
    res.headers.contentType =
        ContentType('application', 'dash+xml');
    res.write('''<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
     mediaPresentationDuration="PT8S" minBufferTime="PT2S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="1000000">
        <BaseURL>seg0.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''');
    return res.close();
  }
}
