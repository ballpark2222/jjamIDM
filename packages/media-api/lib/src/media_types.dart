/// Normalized media types (design doc §18). UI never sees raw
/// yt-dlp JSON — everything funnels through these.
library;

/// One selectable stream/format from a resolver probe.
final class MediaFormat {
  const MediaFormat({
    required this.formatId,
    required this.ext,
    this.width,
    this.height,
    this.bitrateKbps,
    this.filesizeBytes,
    this.hasVideo = false,
    this.hasAudio = false,
    this.protocol = 'http', // http | hls | dash | …
    this.label,
    this.url,
  });

  final String formatId;
  final String ext;
  final int? width;
  final int? height;
  final int? bitrateKbps;
  final int? filesizeBytes;
  final bool hasVideo;
  final bool hasAudio;
  final String protocol;
  final String? label;

  /// The resolved direct stream URL (usually a signed CDN link) —
  /// the engine downloads this, never [MediaSelection.pageUrl],
  /// which is the HTML watch page.
  final String? url;

  String get shortLabel =>
      label ??
      '${height != null ? '${height}p' : formatId}'
          '${hasAudio ? '' : ' (no audio)'}';
}

final class MediaSubtitle {
  const MediaSubtitle({required this.lang, required this.ext, this.url});
  final String lang;
  final String ext;
  final String? url;
}

/// Result of probing a page/media URL.
final class MediaProbe {
  const MediaProbe({
    required this.supported,
    this.title,
    this.durationSeconds,
    this.formats = const [],
    this.subtitles = const [],
    this.webpageUrl,
  });

  final bool supported;
  final String? title;
  final int? durationSeconds;
  final List<MediaFormat> formats;
  final List<MediaSubtitle> subtitles;
  final String? webpageUrl;
}

/// What the user picked in the format chooser.
final class MediaSelection {
  const MediaSelection({
    required this.pageUrl,
    this.videoFormatId,
    this.audioFormatId,
    this.subtitleLangs = const [],
    this.outputFileName,
    this.headers = const {},
  });

  final String pageUrl;
  final String? videoFormatId;
  final String? audioFormatId;
  final List<String> subtitleLangs;
  final String? outputFileName;

  /// Browser-context headers (Cookie/Referer/User-Agent) — forwarded
  /// to the resolver and download steps so login-gated media works.
  final Map<String, String> headers;
}

/// A step in a media download plan. Steps are data — the application
/// layer executes them through the engine / muxer ports.
sealed class MediaStep {
  const MediaStep();
}

/// Direct http(s) download handled by the DownloadEngine.
final class EngineDownloadStep extends MediaStep {
  const EngineDownloadStep({
    required this.url,
    required this.outputFileName,
    this.headers = const {},
    this.role = 'main', // main | video | audio | subtitle
  });
  final String url;
  final String outputFileName;
  final Map<String, String> headers;
  final String role;
}

/// Remux/mux handled by the FFmpeg adapter.
final class MuxStep extends MediaStep {
  const MuxStep({
    required this.inputs,
    required this.outputFileName,
    this.subtitleInputs = const [],
  });
  final List<String> inputs;
  final String outputFileName;
  final List<String> subtitleInputs;
}

/// A component downloads the media itself (e.g. yt-dlp for HLS/DASH
/// where plain Range requests can't fetch segments).
final class ComponentDownloadStep extends MediaStep {
  const ComponentDownloadStep({
    required this.componentId,
    required this.outputFileName,
    this.formatId,
  });
  final String componentId; // e.g. 'tool.ytdlp'
  final String outputFileName;
  final String? formatId;
}

/// Ordered plan: engine steps run, then mux, then done.
final class MediaPlan {
  const MediaPlan({required this.steps, required this.finalFileName});
  final List<MediaStep> steps;
  final String finalFileName;
}
