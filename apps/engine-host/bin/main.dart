import 'dart:convert';
import 'dart:io';

import 'package:freedm_adapter_brisk/freedm_adapter_brisk.dart';
import 'package:freedm_engine_host/engine_host_server.dart';

/// freedm-engine-host entry point.
///
/// Usage: freedm-engine-host [--temp-root <dir>]
/// Speaks DownloadEngine Protocol v1 on stdin/stdout (NDJSON-RPC).
Future<void> main(List<String> args) async {
  var tempRoot = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}freedm-engine');
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] == '--temp-root') {
      tempRoot = Directory(args[i + 1]);
    }
  }

  final engine = BriskEngineAdapter(tempRoot: tempRoot);
  final server = EngineHostServer(engine: engine, tempRoot: tempRoot);
  await server.run(
      stdin.transform(utf8.decoder).transform(const LineSplitter()));
}
