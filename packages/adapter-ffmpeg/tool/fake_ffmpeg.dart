import 'dart:convert';
import 'dart:io';

/// Fake ffmpeg for adapter tests:
///   -version            -> banner line on stdout
///   -i a -i b out.mp4   -> concatenates inputs into the output file
/// Appends argv to FAKE_FFMPEG_ARGV_LOG when set.
Future<void> main(List<String> args) async {
  final log = Platform.environment['FAKE_FFMPEG_ARGV_LOG'];
  if (log != null) {
    File(log).writeAsStringSync('${jsonEncode(args)}\n',
        mode: FileMode.append);
  }
  if (args.contains('-version')) {
    stdout.writeln('ffmpeg version fake-1.0 FreeDM test shim');
    return;
  }
  final inputs = <String>[];
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '-i') inputs.add(args[i + 1]);
  }
  final out = args.isNotEmpty ? args.last : null;
  if (inputs.isNotEmpty && out != null) {
    final sink = File(out).openWrite();
    for (final i in inputs) {
      sink.add(File(i).readAsBytesSync());
    }
    await sink.close();
    stderr.writeln('fake-ffmpeg: muxed ${inputs.length} -> $out');
    return;
  }
  stderr.writeln('fake-ffmpeg: unhandled args $args');
  exit(64);
}
