import 'dart:async';
import 'dart:io';

/// Tracks spawned child processes so an engine shutdown can kill
/// them all. Without this, exiting mid-download orphans yt-dlp /
/// ffmpeg — they keep running (and burning CPU) with no parent
/// left to cancel them.
///
/// Process-level safety net only: normal pause/cancel still flows
/// through CancellationToken; this covers the exit path where no
/// token ever fires (stdin EOF, shutdown RPC, host kill).
final class ChildProcessRegistry {
  ChildProcessRegistry._();

  static final Set<Process> _procs = {};

  /// Track [p] for the life of the process — auto-removed on exit.
  static void track(Process p) {
    _procs.add(p);
    unawaited(p.exitCode.whenComplete(() => _procs.remove(p)));
  }

  /// SIGKILL every tracked child. Idempotent; safe to call on an
  /// empty registry.
  static void killAll() {
    for (final p in _procs.toList()) {
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}
