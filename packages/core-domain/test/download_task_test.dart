import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:test/test.dart';

void main() {
  final src = const DownloadSource(
    initialUrl: 'https://a/f.bin',
    referer: 'https://a/page',
  );

  test('effectiveUrl prefers current then final then initial', () {
    expect(src.effectiveUrl, 'https://a/f.bin');
    expect(src.copyWith(finalUrl: 'https://b/f').effectiveUrl, 'https://b/f');
    expect(
      src
          .copyWith(finalUrl: 'https://b/f', currentUrl: 'https://c/f')
          .effectiveUrl,
      'https://c/f',
    );
  });

  test('progress is null until total known', () {
    final t = DownloadTask(
      id: const TaskId('x'),
      kind: TaskKind.file,
      status: DownloadStatus.downloading,
      source: src,
      output: const OutputSpec(targetDirectory: 'd'),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      receivedBytes: 50,
    );
    expect(t.progress, isNull);
    expect(t.copyWith(totalBytes: 100).progress, 0.5);
  });

  test('retry policy backoff', () {
    const p = RetryPolicy();
    expect(p.delayForAttempt(0), const Duration(seconds: 2));
    expect(p.delayForAttempt(1), const Duration(seconds: 4));
    expect(p.canRetry(4), isTrue);
    expect(p.canRetry(5), isFalse);
  });
}
