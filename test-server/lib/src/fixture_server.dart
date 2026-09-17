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

  /// Deterministic payload: byte[i] = (i*seed + i) & 0xFF.
  static List<int> fixtureBytes(int length, {int seed = 7}) =>
      List<int>.generate(length, (i) => (i * seed + i) & 0xFF);

  static const int defaultLength = 1 << 20; // 1 MiB

  static Future<FixtureServer> start({int port = 0}) async {
    final s = FixtureServer._(await HttpServer.bind(
        InternetAddress.loopbackIPv4, port));
    s._server.listen(s._handle);
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
          return _serveFile(req, length: defaultLength);
        case '/file-range':
          return _serveFile(req, length: defaultLength, ranges: true);
        case '/file-no-range':
          return _serveFile(req, length: defaultLength, ranges: false);
        case '/file-slow':
          return _serveFile(req,
              length: defaultLength, ranges: true, chunkDelay: 20);
        case '/file-drop-connection':
          return _drop(req, at: defaultLength ~/ 2);
        case '/file-random-disconnect':
          return _drop(req, at: Random().nextInt(defaultLength - 1) + 1);
        case '/file-auth-cookie':
          if (req.headers.value('cookie')?.contains('session=fixture') ==
              true) {
            return _serveFile(req, length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.unauthorized);
        case '/file-auth-header':
          if (req.headers.value('authorization') == 'Bearer fixture-token') {
            return _serveFile(req, length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.unauthorized);
        case '/file-auth-referer':
          final ref = req.headers.value('referer') ?? '';
          if (ref.startsWith(base)) {
            return _serveFile(req, length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.forbidden);
        case '/file-redirect':
          res.statusCode = HttpStatus.found;
          res.headers.set('location', '/file-range');
          return res.close();
        case '/issue':
          _token++;
          res.headers.contentType = ContentType.text;
          res.write('/file-expired-url?token=$_token');
          return res.close();
        case '/file-expired-url':
          final tok = int.tryParse(req.uri.queryParameters['token'] ?? '');
          if (tok != null && tok == _token) {
            return _serveFile(req, length: defaultLength, ranges: true);
          }
          return _deny(res, HttpStatus.forbidden);
        case '/file-changing-etag':
          return _serveFile(req,
              length: defaultLength,
              ranges: true,
              etag: '"${Random().nextInt(1 << 31)}"');
        case '/file-changing-length':
          return _serveFile(req,
              length: defaultLength + Random().nextInt(4096),
              ranges: true);
        case '/hls/master.m3u8':
          return _hls(res);
        case '/dash/manifest.mpd':
          return _dash(res);
        default:
          if (req.uri.path.startsWith('/hls/seg')) {
            return _serveFile(req, length: 64 * 1024, seed: 11);
          }
          if (req.uri.path.startsWith('/dash/seg')) {
            return _serveFile(req, length: 64 * 1024, seed: 13);
          }
          res.statusCode = HttpStatus.notFound;
          return res.close();
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
  }) async {
    final res = req.response;
    res.headers.set('etag', etag ?? '"fixture-$seed-$length"');
    res.headers.set('last-modified', 'Thu, 01 Jan 2026 00:00:00 GMT');
    res.headers.set('accept-ranges', ranges ? 'bytes' : 'none');
    res.headers.contentType =
        ContentType('application', 'octet-stream');

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
      res.add(fixtureBytes(n, seed: seed + (off ~/ chunk)));
      if (chunkDelay > 0) {
        await res.flush();
        await Future<void>.delayed(Duration(milliseconds: chunkDelay));
      }
      off += n;
    }
    return res.close();
  }

  /// Announces [defaultLength] via Content-Length, detaches the socket
  /// after headers are sent, then writes only [at] bytes before
  /// destroying the connection — the client sees a truncated body.
  Future<void> _drop(HttpRequest req, {required int at}) async {
    final res = req.response;
    res.headers.set('etag', '"fixture-drop"');
    res.contentLength = defaultLength;
    final socket = await res.detachSocket();
    socket.add(fixtureBytes(at));
    await socket.flush();
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
