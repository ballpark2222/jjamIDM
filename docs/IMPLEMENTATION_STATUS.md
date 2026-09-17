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
- M4 persistence + scheduler: JsonTaskRepository (TaskRepository port,
  atomic-ish flush), DownloadScheduler (concurrency cap, priority
  queue, retry policy, speed-policy plumbing, restart recovery) —
  12 tests pass. ADR 0004: JSON now, SQLite via component manager.
- M5 native host: Rust (gnu toolchain), Browser Protocol v1 framing,
  origin/command/URL validation, engine cold-launch + NDJSON bridge,
  streaming task events — 10 checks + full E2E pass.
- M6 extension MV3: download auto-capture, context menu
  (link/page/selected-links), cookie+referer+UA propagation, popup
  (toggle, task list, pause/resume/cancel).
- M7-9 media layer: media-api normalized ports (resolver/muxer),
  yt-dlp adapter (argv-vector process, JSON probe, plan builder),
  FFmpeg adapter (argv-vector mux/subtitle/version probe) —
  10 adapter tests pass via Dart fake-binary shims.
- M10 media detection: MediaUrlClassifier (host/extension/
  content-type signals → file|media pipeline) — 5 tests pass.
- M11 URL refresh: UrlRefreshResolver port, SameFileValidator
  (etag/lastModified/length/contentType → match|indeterminate|
  conflict), scheduler wiring (urlExpired|forbidden → refresh →
  replaceSource → continue partial; conflict fails the task) —
  11 tests pass.
- M12 component manager: update-api (candidate/store/verifier ports),
  ComponentManager (check→fetch→verify→install→atomic activate→GC),
  version pinning, rollback, engine-affinity refs, Sha256OnlyVerifier,
  LocalBundleStore (atomic state.json) — 5 tests pass.
- M13 upstream pipeline: registry parser, UpstreamWatch (GitHub API,
  injectable fetch), BundleBuilder (deterministic .fdmbundle =
  ustar payload + per-file sha256 manifest + patch-queue provenance),
  tools/upstream-watch + tools/component-build — 9 tests pass;
  live run verified against GitHub (docs/upstream-report.json).

## In Progress

- (none)

## Not Started

- M14 desktop UI (Flutter — SDK not installed)
- M15 RC packaging + audit handoff

## Blockers

- (none)

## Test Summary

- unit: core-domain 13, event-bus 1, persistence 4, media-api 5,
  update-api 14
- application: scheduler 8 + url-refresh 11 (refresh→resume,
  same-file conflict, refresh failure, manual refreshSource)
- contract: adapter-brisk 8, adapter-ytdlp 6, adapter-ffmpeg 4
- integration: fixture server 12
- e2e: native host → engine host → brisk → disk (M5)
- total: 71 dart tests green

## Known Limitations (for audit notes)

- Brisk dynamic segment-reuse can strand byte ranges when multiple
  connections die mid-flight simultaneously (upstream tree desync,
  "Failed to find node index"). Single-connection drop/retry/resume
  verified. Mitigation path: cap connections on flaky servers, or
  upstream fix.
- Brisk aggregate progress message reports totalReceivedBytes=0;
  adapter sums per-connection counts instead.
- Brisk has no speed limiter — FreeDM throttle layer required (M4).
- Sha256OnlyVerifier checks hashes only; release builds must plug a
  minisign/ed25519 SignatureVerifier against a pinned public key.
- yt-dlp/FFmpeg adapters verified against fake shims; real-binary
  contract tests deferred to M15 release verification.

## Environment notes

- OS: Windows (user machine). git 2.39, node 24, python 3.10 present.
- Dart SDK 3.13.4 vendored at `../.tools/dart-sdk` (outside repo, not committed).
- Rust 1.98.1 (gnu toolchain) installed — native-host builds.
- Flutter SDK: NOT installed — required only at M14 (desktop GUI).
