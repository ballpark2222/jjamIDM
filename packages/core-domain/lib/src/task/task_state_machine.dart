import 'download_status.dart';
import 'download_task.dart';
import 'error_code.dart';

/// Thrown when an illegal transition is attempted.
final class InvalidTransitionError extends Error {
  InvalidTransitionError(this.from, this.to);
  final DownloadStatus from;
  final DownloadStatus to;
  @override
  String toString() => 'InvalidTransition: $from -> $to';
}

/// The ONLY place task status transitions are decided (design doc §9:
/// "State transition은 Domain에서만 결정한다").
///
/// Transition table covers both the file pipeline and the media
/// pipeline; terminal states accept no transitions.
final class TaskStateMachine {
  const TaskStateMachine();

  static final Map<DownloadStatus, Set<DownloadStatus>> _allowed = {
    DownloadStatus.created: {
      DownloadStatus.resolving,
      DownloadStatus.resolvingMedia,
      DownloadStatus.cancelled,
    },
    DownloadStatus.resolving: {
      DownloadStatus.ready,
      DownloadStatus.authRequired,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.resolvingMedia: {
      DownloadStatus.ready,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.ready: {
      DownloadStatus.downloading,
      DownloadStatus.downloadingVideo,
      DownloadStatus.cancelled,
    },
    DownloadStatus.downloading: {
      DownloadStatus.pausing,
      DownloadStatus.retryWait,
      DownloadStatus.authRequired,
      DownloadStatus.urlExpired,
      DownloadStatus.verifying,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.downloadingVideo: {
      DownloadStatus.pausing,
      DownloadStatus.downloadingAudio,
      DownloadStatus.muxing,
      DownloadStatus.retryWait,
      DownloadStatus.urlExpired,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.downloadingAudio: {
      DownloadStatus.pausing,
      DownloadStatus.muxing,
      DownloadStatus.retryWait,
      DownloadStatus.urlExpired,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.pausing: {
      DownloadStatus.paused,
      DownloadStatus.downloading, // pause request raced with resume
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.paused: {
      DownloadStatus.downloading,
      DownloadStatus.downloadingVideo,
      DownloadStatus.downloadingAudio,
      DownloadStatus.cancelled,
    },
    DownloadStatus.retryWait: {
      DownloadStatus.downloading,
      DownloadStatus.paused,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.authRequired: {
      DownloadStatus.resolving, // credentials supplied → re-resolve
      DownloadStatus.downloading,
      DownloadStatus.paused,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.urlExpired: {
      DownloadStatus.downloading, // replaceSource() succeeded
      DownloadStatus.downloadingVideo,
      DownloadStatus.downloadingAudio,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.verifying: {
      DownloadStatus.postProcessing,
      DownloadStatus.completed,
      DownloadStatus.failed,
    },
    DownloadStatus.muxing: {
      DownloadStatus.subtitleProcessing,
      DownloadStatus.verifying,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.subtitleProcessing: {
      DownloadStatus.verifying,
      DownloadStatus.failed,
      DownloadStatus.cancelled,
    },
    DownloadStatus.postProcessing: {
      DownloadStatus.completed,
      DownloadStatus.failed,
    },
    // terminal
    DownloadStatus.completed: const {},
    DownloadStatus.failed: const {},
    DownloadStatus.cancelled: const {},
  };

  bool canTransition(DownloadStatus from, DownloadStatus to) =>
      _allowed[from]?.contains(to) ?? false;

  /// Returns a copy of [task] at [to]. Throws [InvalidTransitionError]
  /// on illegal transitions — callers must not catch-and-continue.
  DownloadTask transition(
    DownloadTask task,
    DownloadStatus to, {
    DateTime? at,
    int? receivedBytes,
    int? totalBytes,
    int? failedAttempts,
    ErrorCode? lastError,
  }) {
    if (!canTransition(task.status, to)) {
      throw InvalidTransitionError(task.status, to);
    }
    return task.copyWith(
      status: to,
      updatedAt: at ?? DateTime.now().toUtc(),
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      failedAttempts: failedAttempts,
      lastError: lastError,
    );
  }
}
