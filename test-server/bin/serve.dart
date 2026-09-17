import 'dart:io';

import 'package:freedm_test_server/src/fixture_server.dart';

/// Standalone fixture server for E2E tests: prints `PORT <n>` then
/// serves until killed.
Future<void> main() async {
  final srv = await FixtureServer.start();
  stdout.writeln('PORT ${srv.port}');
}
