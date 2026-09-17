import 'dart:io';

import 'package:flutter/material.dart';
import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:freedm_engine_host/engine_client.dart';
import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:freedm_persistence/freedm_persistence.dart';
import 'package:freedm_update_api/freedm_update_api.dart';

import 'desktop_controller.dart';

/// Pinned bundle-signing public key (Ed25519, fdmsig/1). Bundles
/// without a valid signature from this key are refused. The
/// private seed lives outside the repo (release signing only).
/// Dev key generated via tools/component-sign/sign_bundle.dart.
const _signingKeyHex =
    'f3096dd54ae7c2ec1abcbb2db13b30fa90315a67de52e78bb9af4a5d40cea9ac';
final _signingKey = List<int>.generate(
    _signingKeyHex.length ~/ 2,
    (i) => int.parse(
        _signingKeyHex.substring(i * 2, i * 2 + 2),
        radix: 16));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dataDir =
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}FreeDM';
  final downloadDir =
      '${Platform.environment['USERPROFILE'] ?? dataDir}'
          '${Platform.pathSeparator}Downloads'
          '${Platform.pathSeparator}FreeDM';
  await Directory('$dataDir${Platform.pathSeparator}tasks')
      .create(recursive: true);
  await Directory(downloadDir).create(recursive: true);

  // Control plane ↔ engine bundle boundary: engine-host is spawned
  // and spoken to over NDJSON-RPC (DownloadEngine Protocol v1).
  final sep = Platform.pathSeparator;
  final engine = await EngineHostClient.spawn([
    _dartExe(sep),
    '${_repoRoot()}$sep/apps${sep}engine-host${sep}bin${sep}main.dart',
    '--temp-root',
    '$dataDir${sep}engine-temp',
  ]);

  final scheduler = DownloadScheduler(
    engine: engine,
    repository: await JsonTaskRepository.open(
        Directory('$dataDir${Platform.pathSeparator}tasks')),
    eventBus: InMemoryEventBus(),
    idGenerator: _sequentialIds(),
  );
  await scheduler.recover();

  final components = ComponentManager(
    source: const _RegistrySource(),
    fetcher: _HttpFetcher(),
    store: LocalBundleStore(
        '$dataDir${Platform.pathSeparator}components'),
    verifier:
        Ed25519SignatureVerifier(trustedPublicKey: _signingKey),
  );

  final controller = DesktopController(
    scheduler: scheduler,
    components: components,
    downloadDir: downloadDir,
  );
  await controller.loadExisting();
  runApp(FreeDmApp(controller: controller));
}

/// Walk up from cwd until `apps/engine-host/bin/main.dart` exists —
/// dev runs happen inside the repo; packaged builds ship the
/// engine-host next to the app.
String _repoRoot() {
  final sep = Platform.pathSeparator;
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File(
            '${dir.path}${sep}apps${sep}engine-host${sep}bin${sep}main.dart')
        .existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return Directory.current.path;
}

String _dartExe(String sep) {
  final vendored = File(
      '${_repoRoot()}$sep..${sep}.tools${sep}dart-sdk${sep}bin${sep}dart.exe');
  if (vendored.existsSync()) return vendored.path;
  return Platform.isWindows ? 'dart.exe' : 'dart';
}

TaskId Function() _sequentialIds() {
  var n = 0;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  return () => TaskId('d$stamp-${n++}');
}

/// Dev-stage update source: reads upstream-registry + asks GitHub
/// for latest releases, returning candidates only for binary
/// components (vendored sources build through the pipeline tool).
final class _RegistrySource implements UpdateSource {
  const _RegistrySource();
  @override
  Future<ComponentCandidate?> latestFor(String componentId) async =>
      null; // wired to UpstreamWatch results in release builds
}

final class _HttpFetcher implements BundleFetcher {
  @override
  Future<List<int>> fetch(String bundleUrl) async {
    final req = await HttpClient().getUrl(Uri.parse(bundleUrl));
    final res = await req.close();
    final b = await res.expand((c) => c).toList();
    return b;
  }
}

class FreeDmApp extends StatelessWidget {
  const FreeDmApp({super.key, required this.controller});
  final DesktopController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FreeDM',
        theme: ThemeData(
            colorSchemeSeed: Colors.blueGrey,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: HomePage(controller: controller),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final DesktopController controller;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('FreeDM'), actions: [
        IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh components',
            onPressed: c.refreshComponents),
      ]),
      body: _tab == 0 ? _downloadList(c) : _componentList(c),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              onPressed: () => _addDialog(context, c),
              icon: const Icon(Icons.add),
              label: const Text('Add URL'))
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.download), label: 'Downloads'),
          NavigationDestination(
              icon: Icon(Icons.extension), label: 'Components'),
        ],
      ),
    );
  }

  Widget _downloadList(DesktopController c) {
    return AnimatedBuilder(
      animation: c,
      builder: (_, _) {
        final tasks = c.tasks;
        if (tasks.isEmpty) {
          return const Center(
              child: Text('No downloads yet — add a URL.'));
        }
        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (_, i) => _TaskTile(task: tasks[i], c: c),
        );
      },
    );
  }

  Widget _componentList(DesktopController c) {
    return AnimatedBuilder(
      animation: c,
      builder: (_, _) {
        final states = c.componentStates;
        if (states.isEmpty) {
          return const Center(child: Text('No components.'));
        }
        return ListView(children: [
          for (final e in states.entries)
            ListTile(
              title: Text(e.key),
              subtitle: Text(
                  'active: ${e.value.activeVersion ?? '—'}  '
                  'installed: ${e.value.installed.keys.join(', ')}'
                  '${e.value.pinned ? '  (pinned)' : ''}'),
              trailing: Wrap(spacing: 4, children: [
                IconButton(
                    icon: const Icon(Icons.system_update),
                    tooltip: 'Update',
                    onPressed: e.value.pinned
                        ? null
                        : () => c.updateComponent(e.key)),
                IconButton(
                    icon: Icon(e.value.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined),
                    tooltip: e.value.pinned ? 'Unpin' : 'Pin version',
                    onPressed: () =>
                        c.togglePin(e.key, !e.value.pinned)),
              ]),
            ),
        ]);
      },
    );
  }

  Future<void> _addDialog(
      BuildContext context, DesktopController c) async {
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add download'),
        content: TextField(
          controller: url,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'URL', hintText: 'https://…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download')),
        ],
      ),
    );
    if (ok == true && url.text.trim().isNotEmpty) {
      await c.addDownload(url.text.trim());
    }
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.c});
  final DownloadTask task;
  final DesktopController c;

  @override
  Widget build(BuildContext context) {
    final p = taskProgress(task);
    final status = task.status.name;
    return ListTile(
      title: Text(taskFileName(task),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (p >= 0)
            LinearProgressIndicator(value: p)
          else if (task.status.isActive)
            const LinearProgressIndicator(),
          const SizedBox(height: 4),
          Text(
            '$status  ·  ${fmtBytes(task.receivedBytes)}'
            '${task.totalBytes != null ? ' / ${fmtBytes(task.totalBytes)}' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: Wrap(spacing: 0, children: [
        if (task.status.isActive)
          IconButton(
              icon: const Icon(Icons.pause),
              tooltip: 'Pause',
              onPressed: () => c.pause(task.id)),
        if (task.status == DownloadStatus.paused)
          IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Resume',
              onPressed: () => c.resume(task.id)),
        if (task.status == DownloadStatus.urlExpired)
          IconButton(
              icon: const Icon(Icons.link),
              tooltip: 'Refresh URL',
              onPressed: () => c.refreshUrl(task.id)),
        if (!task.status.isTerminal)
          IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: () => c.cancel(task.id)),
        if (task.status.isTerminal)
          IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: () => c.remove(task.id)),
      ]),
    );
  }
}
