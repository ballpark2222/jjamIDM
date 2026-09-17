# Status

## Completed

- (in progress) M0 bootstrap: repo skeleton, AGENTS.md, ADR framework,
  workspace layout, upstream-registry.yaml, components.lock

## In Progress

- M0 — repository bootstrap

## Not Started

- M1 core-domain · M2 test-server · M3 engine-host+Brisk adapter
- M4 persistence/queue/scheduler · M5 native-host (Rust)
- M6 browser extension · M7 media APIs · M8 yt-dlp · M9 FFmpeg
- M10 media detection · M11 URL refresh · M12 component manager
- M13 upstream pipeline · M14 UI hardening · M15 RC + audit handoff

## Blockers

- (none yet)

## Test Summary

- unit: n/a
- contract: n/a
- integration: n/a
- e2e: n/a

## Environment notes

- OS: Windows (user machine). git 2.39, node 24, python 3.10 present.
- Dart SDK 3.13.4 vendored at `../.tools/dart-sdk` (outside repo, not committed).
- Flutter SDK: NOT installed — required only at M14 (desktop GUI).
- Rust toolchain: NOT installed — required at M5.
