import 'dart:io';

import 'package:freedm_test_server/src/fixture_server.dart';
import 'package:test/test.dart';

void main() {
  late FixtureServer srv;
  late HttpClient http;

  setUp(() async {
    srv = await FixtureServer.start();
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await srv.close();
  });

  Future<HttpClientResponse> get(String path,
      {Map<String, String>? headers, String method = 'GET'}) async {
    final req = await http.openUrl(method, Uri.parse('${srv.base}$path'));
    headers?.forEach(req.headers.set);
    return req.close();
  }

  test('/file returns 200 with full length', () async {
    final r = await get('/file');
    expect(r.statusCode, 200);
    expect(r.contentLength, FixtureServer.defaultLength);
    await r.drain<void>();
  });

  test('/file-range honours Range with 206', () async {
    final r = await get('/file-range', headers: {'range': 'bytes=0-99'});
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'), 'bytes 0-99/1048576');
    final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(body.length, 100);
    expect(body, FixtureServer.fixtureBytes(100));
  });

  test('/file-no-range ignores Range', () async {
    final r = await get('/file-no-range', headers: {'range': 'bytes=0-99'});
    expect(r.statusCode, 200);
    await r.drain<void>();
  });

  test('/file-auth-cookie rejects then accepts', () async {
    expect((await get('/file-auth-cookie')).statusCode, 401);
    final r = await get('/file-auth-cookie',
        headers: {'cookie': 'session=fixture'});
    expect(r.statusCode, 200);
    await r.drain<void>();
  });

  test('/file-auth-header rejects then accepts', () async {
    expect((await get('/file-auth-header')).statusCode, 401);
    final r = await get('/file-auth-header',
        headers: {'authorization': 'Bearer fixture-token'});
    expect(r.statusCode, 200);
    await r.drain<void>();
  });

  test('/file-auth-referer rejects then accepts', () async {
    expect((await get('/file-auth-referer')).statusCode, 403);
    final r = await get('/file-auth-referer',
        headers: {'referer': '${srv.base}/page'});
    expect(r.statusCode, 200);
    await r.drain<void>();
  });

  test('/file-redirect points at /file-range', () async {
    final req = await http.getUrl(Uri.parse('${srv.base}/file-redirect'));
    req.followRedirects = false;
    final r = await req.close();
    expect(r.statusCode, 302);
    expect(r.headers.value('location'), '/file-range');
    await r.drain<void>();
  });

  test('/file-expired-url: issued token works, next issue expires it',
      () async {
    final issue1 = await get('/issue');
    final path1 = await issue1
        .transform(const SystemEncoding().decoder)
        .join();
    expect((await get(path1)).statusCode, 200);

    // issuing a new token invalidates the old URL (signed-url expiry)
    final issue2 = await get('/issue');
    await issue2.drain<void>();
    expect((await get(path1)).statusCode, 403);
  });

  test('/file-drop-connection truncates the body', () async {
    final r = await get('/file-drop-connection');
    var received = 0;
    Object? error;
    try {
      await for (final chunk in r) {
        received += chunk.length;
      }
    } on HttpException catch (e) {
      error = e;
    }
    // server announced full length but killed the socket mid-body
    expect(received, lessThan(FixtureServer.defaultLength));
    expect(received, greaterThan(0));
    expect(error, isA<HttpException>());
  });

  test('/file-changing-etag varies', () async {
    final e1 = (await get('/file-changing-etag')).headers.value('etag');
    final e2 = (await get('/file-changing-etag')).headers.value('etag');
    expect(e1, isNot(e2));
  });

  test('/hls/master.m3u8 serves playlist + segments', () async {
    final r = await get('/hls/master.m3u8');
    final body =
        await r.transform(const SystemEncoding().decoder).join();
    expect(body, contains('#EXTM3U'));
    expect(body, contains('seg0.ts'));
    final seg = await get('/hls/seg0.ts');
    expect(seg.statusCode, 200);
    await seg.drain<void>();
  });

  test('/dash/manifest.mpd serves manifest + segment', () async {
    final r = await get('/dash/manifest.mpd');
    final body =
        await r.transform(const SystemEncoding().decoder).join();
    expect(body, contains('MPD'));
    final seg = await get('/dash/seg0.mp4');
    expect(seg.statusCode, 200);
    await seg.drain<void>();
  });
}
