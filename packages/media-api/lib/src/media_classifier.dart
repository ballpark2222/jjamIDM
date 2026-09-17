/// Classification of a captured URL into the file pipeline or the
/// media pipeline (design doc §19). Pure Dart — no resolver process
/// is spawned here; this only decides which pipeline to consult.
library;

enum MediaUrlKind {
  /// Ordinary HTTP(S) file — hand to the download engine.
  directFile,

  /// A media *file* URL (mp4/m3u8/mpd…) — engine can fetch it, but
  /// the resolver may offer better variants (hls/dash need a plan).
  directMedia,

  /// A watch/embed page on a known media site — must go through the
  /// MediaResolver (yt-dlp) before anything is downloadable.
  mediaPage,
}

final class MediaClassification {
  const MediaClassification(this.kind, {this.reason});
  final MediaUrlKind kind;
  final String? reason;

  bool get needsResolver => kind == MediaUrlKind.mediaPage;
}

/// Stateless URL classifier. Host matching is suffix-based so
/// `m.youtube.com` and `www.youtube.com` both hit.
final class MediaUrlClassifier {
  const MediaUrlClassifier();

  /// Hosts whose pages are never direct files. Kept deliberately
  /// short — the resolver still has the final say via
  /// `MediaProbe.supported`.
  static const mediaPageHosts = [
    'youtube.com', 'youtu.be', 'youtube-nocookie.com',
    'vimeo.com', 'twitch.tv', 'tiktok.com', 'dailymotion.com',
    'soundcloud.com', 'bilibili.com', 'niconico.jp',
    'instagram.com', 'facebook.com', 'x.com', 'twitter.com',
    'reddit.com', 'streamable.com', 'rumble.com', 'odysee.com',
  ];

  /// Path extensions that identify a media file or manifest.
  static const mediaFileExtensions = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts', 'm2ts',
    'mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'wma',
    'm3u8', 'mpd',
  };

  /// Manifest/mime types that force the media pipeline even on an
  /// unknown host.
  static const mediaContentPrefixes = ['video/', 'audio/'];
  static const mediaContentTypes = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'application/dash+xml',
  };

  MediaClassification classify(Uri url, {String? contentType}) {
    if (url.scheme != 'http' && url.scheme != 'https') {
      return const MediaClassification(MediaUrlKind.directFile,
          reason: 'non-http scheme: engine decides');
    }
    final ct = contentType?.toLowerCase();
    if (ct != null &&
        (mediaContentTypes.contains(ct) ||
            mediaContentPrefixes.any(ct.startsWith))) {
      return MediaClassification(MediaUrlKind.directMedia,
          reason: 'content-type $ct');
    }
    final host = url.host.toLowerCase();
    if (mediaPageHosts.any((h) => host == h || host.endsWith('.$h'))) {
      // Obvious file URLs on media hosts (e.g. CDN links) still
      // classify as media files, not pages.
      final ext = _ext(url);
      if (ext != null && mediaFileExtensions.contains(ext)) {
        return MediaClassification(MediaUrlKind.directMedia,
            reason: 'media file .$ext on media host');
      }
      return const MediaClassification(MediaUrlKind.mediaPage,
          reason: 'known media host');
    }
    final ext = _ext(url);
    if (ext != null && mediaFileExtensions.contains(ext)) {
      return MediaClassification(MediaUrlKind.directMedia,
          reason: 'media extension .$ext');
    }
    return const MediaClassification(MediaUrlKind.directFile);
  }

  String? _ext(Uri url) {
    final path = url.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    return path.substring(dot + 1);
  }
}
