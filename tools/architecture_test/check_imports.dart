// FreeDM architecture dependency check.
// Scans Dart sources and fails CI when a forbidden import/execution
// crosses an architecture boundary (design doc §7, prompt §20).
//
// Run: dart tools/architecture_test/check_imports.dart
import 'dart:io';

class Rule {
  Rule(this.scopePrefix, this.forbidden, this.reason);
  final String scopePrefix; // path prefix relative to repo root
  final List<Pattern> forbidden;
  final String reason;
}

final rules = <Rule>[
  Rule('packages/core-domain', [
    RegExp(r"package:freedm_adapter_\w+"),
    RegExp(r"package:brisk_(download_)?engine"),
    RegExp(r"yt-dlp|yt_dlp"),
    RegExp(r"ffmpeg"),
    RegExp(r"package:http/"), // transport belongs to adapters/engine
    RegExp(r"dart:io"), // domain stays pure/deterministic
  ], 'core-domain must depend only on port APIs (P2 dependency inversion)'),
  Rule('packages/application', [
    RegExp(r"package:brisk_(download_)?engine"),
    RegExp(r"Process\.start\(.*yt-?dlp"),
    RegExp(r"Process\.start\(.*ffmpeg"),
    RegExp(r"package:freedm_adapter_\w+"),
  ], 'application may not import concrete external providers'),
  Rule('apps/desktop', [
    RegExp(r"package:brisk_(download_)?engine"),
    RegExp(r"package:freedm_adapter_\w+"),
    RegExp(r"Process\.start\("),
    RegExp(r"package:sqlite3/"),
  ], 'UI/control-plane must not reach engines, external binaries, or raw DB'),
  Rule('packages/engine-protocol', [
    RegExp(r"package:brisk_(download_)?engine"),
    RegExp(r"dart:io"),
  ], 'protocol contracts are pure data + types'),
];

// Adapter-specific sanity: only adapter-brisk may import brisk engine.
final adapterRules = <Rule>[
  Rule('packages/adapter-ytdlp', [
    RegExp(r"package:brisk_(download_)?engine"),
  ], 'ytdlp adapter must not import brisk'),
  Rule('packages/adapter-ffmpeg', [
    RegExp(r"package:brisk_(download_)?engine"),
  ], 'ffmpeg adapter must not import brisk'),
];

void main() {
  final violations = <String>[];
  final all = [...rules, ...adapterRules];
  for (final rule in all) {
    final dir = Directory(rule.scopePrefix);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final pat in rule.forbidden) {
          if (pat.allMatches(lines[i]).isNotEmpty) {
            violations.add(
              '${entity.path}:${i + 1}: ${lines[i].trim()}\n'
              '    └ ${rule.reason}',
            );
          }
        }
      }
    }
  }
  if (violations.isEmpty) {
    stdout.writeln('architecture check: OK (${all.length} scopes scanned)');
    return;
  }
  stderr.writeln('architecture check FAILED:');
  violations.forEach(stderr.writeln);
  exit(1);
}
