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
