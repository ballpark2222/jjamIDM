import 'dart:convert';
import 'dart:io';

import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('freedm-repo');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  DownloadTask task(String id,
          {DownloadStatus status = DownloadStatus.ready,
          int priority = 0,
          String? queueId}) =>
      DownloadTask(
        id: TaskId(id),
        kind: TaskKind.file,
        status: status,
        source: DownloadSource(
          initialUrl: 'http://x/$id.bin',
          referer: 'http://page/',
          credentialRef: 'credential://abc',
          etag: '"e$id"',
          contentLength: 42,
        ),
        output: OutputSpec(
          targetDirectory: dir.path,
          checksum: 'sha256:deadbeef',
        ),
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        priority: priority,
        queueId: queueId,
        providerId: 'engine.brisk',
        receivedBytes: 7,
        totalBytes: 42,
        failedAttempts: 1,
        lastError: ErrorCode.connectionDropped,
        engineComponentId: 'brisk-engine',
        engineBundleVersion: 'ec9e4f1',
        engineStateSchema: 1,
      );

  test('round-trips all task fields across reopen', () async {
    var repo = await JsonTaskRepository.open(dir);
    await repo.upsert(task('t1', status: DownloadStatus.paused));

    repo = await JsonTaskRepository.open(dir); // reopen from disk
    final t = await repo.get(const TaskId('t1'));
    expect(t, isNotNull);
    expect(t!.status, DownloadStatus.paused);
    expect(t.source.referer, 'http://page/');
    expect(t.source.credentialRef, 'credential://abc');
    expect(t.source.etag, '"et1"');
    expect(t.output.checksum, 'sha256:deadbeef');
    expect(t.receivedBytes, 7);
    expect(t.failedAttempts, 1);
    expect(t.lastError, ErrorCode.connectionDropped);
    expect(t.engineComponentId, 'brisk-engine');
    expect(t.engineBundleVersion, 'ec9e4f1');
  });

  test('listActive returns resumable states only', () async {
    final repo = await JsonTaskRepository.open(dir);
    await repo.upsert(task('done', status: DownloadStatus.completed));
    await repo.upsert(task('run', status: DownloadStatus.downloading));
    await repo.upsert(task('p', status: DownloadStatus.paused));
    await repo.upsert(task('q', status: DownloadStatus.ready));
    final active = await repo.listActive();
    expect(active.map((t) => t.id.value).toSet(),
        {'run', 'p', 'q'});
  });

  test('queue filter + delete', () async {
    final repo = await JsonTaskRepository.open(dir);
    await repo.upsert(task('a', queueId: 'main'));
    await repo.upsert(task('b', queueId: 'other'));
    expect((await repo.list(queueId: 'main')).single.id.value, 'a');
    await repo.delete(const TaskId('a'));
    expect(await repo.get(const TaskId('a')), isNull);
    expect((await repo.list()).length, 1);
  });

  test('countByEngineBundle for component GC', () async {
    final repo = await JsonTaskRepository.open(dir);
    await repo.upsert(task('x'));
    await repo.upsert(task('y'));
    expect(await repo.countByEngineBundle('brisk-engine', 'ec9e4f1'), 2);
    expect(await repo.countByEngineBundle('brisk-engine', 'other'), 0);
  });

  test('crash mid-flush window: recovers from .bak', () async {
    var repo = await JsonTaskRepository.open(dir);
    await repo.upsert(task('t1', status: DownloadStatus.paused));
    await repo.pending;
    // _flush rotates tasks.json → .bak before renaming tmp into
    // place; a crash in that gap leaves only the .bak. open() must
    // recover it rather than booting an empty queue.
    final f = File('${dir.path}${Platform.pathSeparator}tasks.json');
    await f.rename('${f.path}.bak');

    repo = await JsonTaskRepository.open(dir);
    final t = await repo.get(const TaskId('t1'));
    expect(t, isNotNull);
    expect(t!.status, DownloadStatus.paused);
    // The recovered store is put back where flushes expect it.
    expect(await f.exists(), isTrue);
  });

  test('corrupt store opens empty instead of throwing', () async {
    await File('${dir.path}${Platform.pathSeparator}tasks.json')
        .writeAsString('{{not json');
    final repo = await JsonTaskRepository.open(dir);
    expect(await repo.list(), isEmpty);
  });

  test('one unparseable entry does not lose the rest', () async {
    final first = await JsonTaskRepository.open(dir);
    await first.upsert(task('good'));
    await first.pending;
    final f = File('${dir.path}${Platform.pathSeparator}tasks.json');
    final list = jsonDecode(await f.readAsString()) as List;
    list.add(const {'garbage': true});
    await f.writeAsString(jsonEncode(list));

    final repo = await JsonTaskRepository.open(dir);
    expect(await repo.get(const TaskId('good')), isNotNull);
  });
}
