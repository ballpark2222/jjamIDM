# Status

## Completed

- M0 bootstrap: repo skeleton, AGENTS.md, ADR framework, workspace
  layout, upstream-registry.yaml, components.lock, CI workflows
- M1 core-domain: task model, state machine, DownloadEngine API,
  typed event bus, persistence interface — 13+ unit tests pass
- M2 test-server: deterministic fixtures (range, auth, redirect,
  expire, drop, changing-etag, HLS, DASH) — 12 tests pass
- M3 engine-host + Brisk adapter: vendored brisk-engine
  (ec9e4f1, MIT) with patch queue, NDJSON protocol v1, engine-host
  process, adapter contract tests — 8 tests pass

## In Progress

- M4 — persistence/queue/scheduler

## Not Started

- M5 native-host (Rust) · M6 browser extension · M7 media APIs
- M8 yt-dlp · M9 FFmpeg · M10 media detection · M11 URL refresh
- M12 component manager · M13 upstream pipeline · M14 UI
- M15 RC + audit handoff

## Blockers

- (none)

## Test Summary

- unit: core-domain 13, event-bus (in M1 batch), protocol DTOs
- contract: adapter-brisk 8 (probe, caps, full+hash, pause/resume,
  cookie auth, restart-resume, drop-retry, cancel)
- integration: fixture server 12
- e2e: n/a

## Known Limitations (for audit notes)

- Brisk dynamic segment-reuse can strand byte ranges when multiple
  connections die mid-flight simultaneously (upstream tree desync,
  "Failed to find node index"). Single-connection drop/retry/resume
  verified. Mitigation path: cap connections on flaky servers, or
  upstream fix.
- Brisk aggregate progress message reports totalReceivedBytes=0;
  adapter sums per-connection counts instead.
- Brisk has no speed limiter — FreeDM throttle layer required (M4).

## Environment notes

- OS: Windows (user machine). git 2.39, node 24, python 3.10 present.
- Dart SDK 3.13.4 vendored at `../.tools/dart-sdk` (outside repo, not committed).
- Flutter SDK: NOT installed — required only at M14 (desktop GUI).
- Rust toolchain: NOT installed — required at M5.
