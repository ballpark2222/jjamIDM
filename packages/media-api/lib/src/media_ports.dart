import 'media_types.dart';

/// Port: turns a page/media URL into normalized formats and a
/// download plan (design doc §18). Implemented by adapter-ytdlp —
/// the UI must never parse raw resolver output.
abstract interface class MediaResolver {
  String get providerId; // e.g. 'media.ytdlp'
  int get apiVersion;

  /// Inspect [pageUrl]; returns formats/subtitles or supported:false.
  Future<MediaProbe> probe(String pageUrl,
      {Map<String, String> headers = const {}, String? cookieRef});

  /// Turn a user selection into an ordered plan of steps.
  Future<MediaPlan> plan(MediaSelection selection,
      {Map<String, String> headers = const {}});

  /// Resolver binary version (for component update/self-test).
  Future<String> version();
}

/// Port: a component that downloads media itself (HLS/DASH segments,
/// yt-dlp-managed fetches) where plain Range requests can't work.
/// Implemented by adapter-ytdlp; keyed by componentId in the plan.
abstract interface class ComponentDownloader {
  String get componentId; // e.g. 'tool.ytdlp' / 'media.ytdlp'

  /// Download [pageUrl] (or the step's format) to [outputPath].
  /// [onProgress] receives 0.0..1.0; returns the process exit code.
  Future<int> download({
    required String pageUrl,
    required String outputPath,
    String? formatId,
    Map<String, String> headers,
    List<String> subtitleLangs,
    void Function(double progress)? onProgress,
  });
}

/// Port: remux/mux/subtitle processing. Implemented by
/// adapter-ffmpeg — the only place FFmpeg argv is built.
abstract interface class MediaMuxer {
  String get providerId; // e.g. 'media.ffmpeg'

  /// Combine inputs into one output file (stream copy — no re-encode).
  Future<MuxResult> mux(MuxStep step, {String workDir});

  /// Burn/attach subtitle files into [videoPath].
  Future<MuxResult> attachSubtitles(
      String videoPath, List<String> subtitlePaths,
      {String? outputPath});

  Future<String> version();
}

final class MuxResult {
  const MuxResult({required this.ok, this.outputPath, this.error});
  final bool ok;
  final String? outputPath;
  final String? error;
}
