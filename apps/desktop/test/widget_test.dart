import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:jjamidm/desktop_controller.dart';
import 'package:jjamidm/main.dart';
import 'package:freedm_download_api/freedm_download_api.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:freedm_update_api/freedm_update_api.dart';

final class FakeEngine implements DownloadEngine {
  final controllers = <String, StreamController<EngineEvent>>{};
  @override
  String get providerId => 'engine.fake';
  @override
  int get apiVersion => 1;
  @override
  Future<EngineCapabilities> capabilities() async =>
      EngineCapabilities(
          segmentedDownload: true,
          dynamicConnections: false,
          resume: true,
          customHeaders: true,
          cookies: true,
          referer: true,
          proxy: false,
          speedLimit: false,
          http2: false,
          ftp: false,
          torrent: false);
  @override
  Future<ProbeResult> probe(DownloadRequest r) async =>
      const ProbeResult(supported: true, totalBytes: 1000);
  @override
  Future<EngineTaskHandle> create(TaskId id, DownloadRequest r) async {
    controllers[id.value] = StreamController<EngineEvent>();
    return EngineTaskHandle(engineTaskId: id.value);
  }
  @override
  Future<void> start(TaskId id) async {}
  @override
  Future<void> pause(TaskId id) async =>
      controllers[id.value]?.add(const EnginePaused());
  @override
  Future<void> resume(TaskId id) async {}
  @override
  Future<void> cancel(TaskId id) async =>
      controllers[id.value]
          ?.add(const EngineFailed(ErrorCode.cancelledByUser));
  @override
  Future<void> checkpoint(TaskId id) async {}
  @override
  Future<void> replaceSource(TaskId id, DownloadRequest r) async {}
  @override
  Future<void> setSpeedLimit(TaskId id, int? b) async {}
  @override
  @override
  bool isKnown(TaskId id) => controllers.containsKey(id.value);
  Stream<EngineEvent> events(TaskId id) =>
      controllers[id.value]!.stream;
}

void main() {
  testWidgets('task list shows enqueued download + progress',
      (tester) async {
    // The scheduler does real file I/O — runAsync gives the body a
    // real event loop instead of the FakeAsync zone.
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('fdesk');
      final engine = FakeEngine();
      final repo = await JsonTaskRepository.open(dir);
      final scheduler = DownloadScheduler(
        engine: engine,
        repository: repo,
        eventBus: InMemoryEventBus(),
        idGenerator: () => TaskId('w${DateTime.now().microsecond}'),
      );
      final c = DesktopController(
        scheduler: scheduler,
        components: ComponentManager(
            source: _NoSource(),
            fetcher: _NoFetch(),
            store: MemoryBundleStore()),
        downloadDir: dir.path,
      );
      await tester.pumpWidget(FreeDmApp(controller: c));

      final t = await c.addDownload('https://x.example/file.bin');
      // enqueue's resolve→create→start pipeline is async — wait for
      // the engine create before driving its event channel.
      for (var i = 0;
          i < 100 && !engine.controllers.containsKey(t.id.value);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(find.text('file.bin'), findsOneWidget);

      engine.controllers[t.id.value]!.add(const EngineProgress(
          receivedBytes: 500, totalBytes: 1000, speedBytesPerSecond: 250));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await scheduler.dispose();
      await c.dispose();
      // Drain pending writes then delete — Windows file locks are
      // briefly held after the last async write.
      await repo.pending;
      for (var i = 0; i < 20; i++) {
        try {
          await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await repo.pending;
        }
      }
    });
  });

  test('fmtBytes/taskProgress helpers', () {
    expect(fmtBytes(0), '0 B');
    expect(fmtBytes(1024), '1.0 KiB');
    expect(fmtBytes(5 * 1024 * 1024), '5.0 MiB');
    expect(fmtBytes(null), '—');
    final t = DownloadTask(
        id: TaskId('a'),
        kind: TaskKind.file,
        status: DownloadStatus.downloading,
        source: const DownloadSource(initialUrl: 'http://x/f.bin'),
        output: const OutputSpec(targetDirectory: '/tmp'),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        providerId: 'e',
        receivedBytes: 50,
        totalBytes: 100);
    expect(taskProgress(t), 0.5);
    expect(taskFileName(t), 'f.bin');
  });
}

final class _NoSource implements UpdateSource {
  @override
  Future<ComponentCandidate?> latestFor(String id) async => null;
}

final class _NoFetch implements BundleFetcher {
  @override
  Future<List<int>> fetch(String u) async => throw UnimplementedError();
}
