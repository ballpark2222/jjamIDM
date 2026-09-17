/// DownloadEngine Protocol — method names and shared constants
/// (design doc §4.2). Pure data; no I/O.
///
/// v2 adds the media.* family (probe/enqueue/cancel + media.event
/// notifications). v1 clients remain functional — the additions are
/// purely additive; a v1 client simply never calls them.
final class EngineProtocol {
  EngineProtocol._();

  static const int version = 2;

  /// Versions this host can serve. v2 ⊃ v1 (additive methods only).
  static const List<int> supportedVersions = [1, 2];

  // commands
  static const String hello = 'engine.hello';
  static const String capabilities = 'engine.capabilities';
  static const String taskProbe = 'task.probe';
  static const String taskCreate = 'task.create';
  static const String taskStart = 'task.start';
  static const String taskPause = 'task.pause';
  static const String taskResume = 'task.resume';
  static const String taskCancel = 'task.cancel';
  static const String taskCheckpoint = 'task.checkpoint';
  static const String taskStatus = 'task.status';
  static const String taskReplaceSource = 'task.replaceSource';
  static const String taskSetSpeedLimit = 'task.setSpeedLimit';
  static const String taskSubscribeEvents = 'task.subscribeEvents';
  static const String selfTest = 'engine.selfTest';
  static const String shutdown = 'engine.shutdown';

  // media pipeline (v2) — resolved/downloaded inside the host via
  // yt-dlp/FFmpeg adapters; UI stays off external processes.
  static const String mediaProbe = 'media.probe';
  static const String mediaEnqueue = 'media.enqueue';
  static const String mediaCancel = 'media.cancel';
  // v2 additive (ADR-0006): pause/resume for media tasks. Engine
  // steps pause via the engine; component (yt-dlp) steps stop and
  // resume from their .part artifacts on resume.
  static const String mediaPause = 'media.pause';
  static const String mediaResume = 'media.resume';

  // server → client notifications
  static const String taskEvent = 'task.event';

  /// Carries a full TaskCodec-encoded DownloadTask snapshot so the
  /// control plane renders media tasks identically to file tasks.
  static const String mediaEvent = 'media.event';
}
