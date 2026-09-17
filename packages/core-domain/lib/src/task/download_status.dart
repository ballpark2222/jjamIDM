/// Task lifecycle states (design doc §9).
///
/// State transitions are decided ONLY by [TaskStateMachine] inside
/// core-domain. Adapters report engine events; they never set state.
enum DownloadStatus {
  created,
  resolving,
  ready,
  downloading,
  pausing,
  paused,
  retryWait,
  authRequired,
  urlExpired,
  verifying,
  postProcessing,
  completed,
  failed,
  cancelled,

  // media pipeline states
  resolvingMedia,
  downloadingVideo,
  downloadingAudio,
  muxing,
  subtitleProcessing,
}

extension DownloadStatusX on DownloadStatus {
  bool get isTerminal =>
      this == DownloadStatus.completed ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.cancelled;

  bool get isActive => switch (this) {
    DownloadStatus.resolving ||
    DownloadStatus.downloading ||
    DownloadStatus.pausing ||
    DownloadStatus.verifying ||
    DownloadStatus.postProcessing ||
    DownloadStatus.resolvingMedia ||
    DownloadStatus.downloadingVideo ||
    DownloadStatus.downloadingAudio ||
    DownloadStatus.muxing ||
    DownloadStatus.subtitleProcessing => true,
    _ => false,
  };
}
