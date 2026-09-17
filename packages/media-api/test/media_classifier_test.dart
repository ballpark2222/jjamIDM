import 'package:freedm_media_api/freedm_media_api.dart';
import 'package:test/test.dart';

void main() {
  const c = MediaUrlClassifier();

  test('watch pages on media hosts → mediaPage (needs resolver)', () {
    for (final u in [
      'https://www.youtube.com/watch?v=abc',
      'https://youtu.be/abc',
      'https://m.youtube.com/shorts/xyz',
      'https://vimeo.com/12345',
      'https://www.twitch.tv/someone/clip/xyz',
    ]) {
      expect(c.classify(Uri.parse(u)).kind, MediaUrlKind.mediaPage,
          reason: u);
    }
  });

  test('media file URLs → directMedia, even on media hosts', () {
    for (final u in [
      'https://cdn.example.com/v/a.mp4',
      'https://files.example.org/song.FLAC?sig=1',
      'https://rr2.googlevideo.com/v/a.webm',
    ]) {
      expect(c.classify(Uri.parse(u)).kind, MediaUrlKind.directMedia,
          reason: u);
    }
  });

  test('manifest extensions → directMedia', () {
    expect(c.classify(Uri.parse('https://hls.example.com/m/master.m3u8')).kind,
        MediaUrlKind.directMedia);
    expect(c.classify(Uri.parse('https://dash.example.com/m/manifest.mpd')).kind,
        MediaUrlKind.directMedia);
  });

  test('content-type forces media classification on unknown hosts', () {
    expect(
        c.classify(Uri.parse('https://x.example/getfile'),
            contentType: 'video/mp4')
            .kind,
        MediaUrlKind.directMedia);
    expect(
        c.classify(Uri.parse('https://x.example/getfile'),
            contentType: 'application/dash+xml')
            .kind,
        MediaUrlKind.directMedia);
  });

  test('plain files and non-http → directFile', () {
    for (final u in [
      'https://example.com/setup.exe',
      'https://example.com/docs/report.pdf',
      'ftp://mirror.example/iso/disk.iso',
      'https://example.com/no-extension',
    ]) {
      expect(c.classify(Uri.parse(u)).kind, MediaUrlKind.directFile,
          reason: u);
    }
  });
}
