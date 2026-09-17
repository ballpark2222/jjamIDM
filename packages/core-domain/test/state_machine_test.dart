import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:test/test.dart';

DownloadTask taskAt(DownloadStatus s) => DownloadTask(
  id: const TaskId('t1'),
  kind: TaskKind.file,
  status: s,
  source: const DownloadSource(initialUrl: 'https://x/f.bin'),
  output: const OutputSpec(targetDirectory: 'dl'),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  const sm = TaskStateMachine();

  group('legal transitions', () {
    test('happy path file download', () {
      var t = taskAt(DownloadStatus.created);
      t = sm.transition(t, DownloadStatus.resolving);
      t = sm.transition(t, DownloadStatus.ready);
      t = sm.transition(t, DownloadStatus.downloading);
      t = sm.transition(t, DownloadStatus.verifying);
      t = sm.transition(t, DownloadStatus.postProcessing);
      t = sm.transition(t, DownloadStatus.completed);
      expect(t.status, DownloadStatus.completed);
    });

    test('pause/resume cycle', () {
      var t = taskAt(DownloadStatus.downloading);
      t = sm.transition(t, DownloadStatus.pausing);
      t = sm.transition(t, DownloadStatus.paused);
      t = sm.transition(t, DownloadStatus.downloading);
      expect(t.status, DownloadStatus.downloading);
    });

    test('url expired → resume after replaceSource', () {
      var t = taskAt(DownloadStatus.downloading);
      t = sm.transition(t, DownloadStatus.urlExpired);
      t = sm.transition(t, DownloadStatus.downloading);
      expect(t.status, DownloadStatus.downloading);
    });

    test('retry wait → downloading → failed', () {
      var t = taskAt(DownloadStatus.downloading);
      t = sm.transition(t, DownloadStatus.retryWait);
      t = sm.transition(t, DownloadStatus.downloading);
      t = sm.transition(t, DownloadStatus.failed);
      expect(t.status.isTerminal, isTrue);
    });

    test('media pipeline', () {
      var t = taskAt(DownloadStatus.created);
      t = sm.transition(t, DownloadStatus.resolvingMedia);
      t = sm.transition(t, DownloadStatus.ready);
      t = sm.transition(t, DownloadStatus.downloadingVideo);
      t = sm.transition(t, DownloadStatus.downloadingAudio);
      t = sm.transition(t, DownloadStatus.muxing);
      t = sm.transition(t, DownloadStatus.subtitleProcessing);
      t = sm.transition(t, DownloadStatus.verifying);
      t = sm.transition(t, DownloadStatus.completed);
      expect(t.status.isTerminal, isTrue);
    });
  });

  group('illegal transitions', () {
    test('terminal states accept nothing', () {
      for (final s in [
        DownloadStatus.completed,
        DownloadStatus.failed,
        DownloadStatus.cancelled,
      ]) {
        expect(
          () => sm.transition(taskAt(s), DownloadStatus.downloading),
          throwsA(isA<InvalidTransitionError>()),
        );
      }
    });

    test('created cannot jump to downloading', () {
      expect(
        () => sm.transition(
          taskAt(DownloadStatus.created),
          DownloadStatus.downloading,
        ),
        throwsA(isA<InvalidTransitionError>()),
      );
    });

    test('paused cannot verify', () {
      expect(
        () => sm.transition(
          taskAt(DownloadStatus.paused),
          DownloadStatus.verifying,
        ),
        throwsA(isA<InvalidTransitionError>()),
      );
    });

    test('downloading cannot go straight to postProcessing', () {
      expect(
        () => sm.transition(
          taskAt(DownloadStatus.downloading),
          DownloadStatus.postProcessing,
        ),
        throwsA(isA<InvalidTransitionError>()),
      );
    });
  });

  test('transition stamps updatedAt', () {
    final t = sm.transition(
      taskAt(DownloadStatus.created),
      DownloadStatus.resolving,
      at: DateTime.utc(2026, 1, 2),
    );
    expect(t.updatedAt, DateTime.utc(2026, 1, 2));
    expect(t.createdAt, DateTime.utc(2026));
  });
}
