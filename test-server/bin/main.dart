import 'package:freedm_test_server/src/fixture_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 0 : int.parse(args[0]);
  final server = await FixtureServer.start(port: port);
  // ignore: avoid_print
  print('fixture-server listening on ${server.base}');
}
