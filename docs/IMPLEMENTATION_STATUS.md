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

- M14 desktop UI: Flutter 3.47.4 app (task list, progress, pause/
  resume/cancel, URL-refresh action, component tab with update/pin/
  rollback), DesktopController view-model, EngineHostClient
  (DownloadEngine over spawned engine-host NDJSON-RPC) +
  task.probe protocol method — widget test + client E2E pass.
  Windows binary needs Visual Studio C++ workload (not installed).
- M15 RC packaging: tools/release/package.ps1 produces
  release/freedm-rc/ (engine-host.exe AOT, native_host.exe release,
  extension, SHA256SUMS.json); docs/AUDIT_HANDOFF.md with provenance
  table, clean-machine verification procedure, and limitations.

- Media pipeline orchestration: MediaDownloadCoordinator drives
  resolvingMedia→downloadingVideo/Audio→muxing→subtitleProcessing→
  verifying→completed through the state machine; ComponentDownloader
  port added to media-api; YtDlpDownloader implements it.
- Real-binary verification: yt-dlp.exe 2026.08.19 probed the local
  HLS fixture AND a live YouTube watch page through YtDlpResolver —
  ~20 formats normalized (codec flags, protocol, sizes).
- Real-binary verification: ffmpeg.exe 9.0.1 (gyan.dev essentials)
  ran FfmpegMuxer.mux over lavfi-synthesized h264+aac inputs;
  ffprobe confirms 1 video + 1 audio stream (tool/real_mux.dart).
- Bundle signing: Ed25519SignatureVerifier (fdmsig/1 — sha256 gate
  plus pinned-key ed25519 over bundle bytes), Ed25519Signer +
  tools/component-sign/sign_bundle.dart (genkey/pubkey/sign);
  desktop app pins the dev public key in ComponentManager.
- Full real media pipeline (tools/real-pipeline): live YouTube page
  → yt-dlp probe → separate audio+video downloads → real ffmpeg mux
  → ffprobe-verified mkv. The IDM-equivalent media flow end to end.
- Real yt-dlp download path (adapter-ytdlp/tool/real_download.dart):
  progressive bytes + progress callbacks on a live page.
- Engine Protocol v2 (ADR 0005): media.probe/enqueue/cancel +
  media.event (TaskCodec task snapshots). engine-host hosts the
  MediaDownloadCoordinator with real yt-dlp/ffmpeg adapters —
  desktop UI stays port-only. Media tasks merge into the same
  task list; URL classifier routes media pages automatically.
- coordinator fix: final artifact is moved into the task's
  targetDirectory (previously stranded in workDir).
- Windows build: VS Build Tools C++ installed; `flutter build
  windows --release` produces freedm_desktop.exe; package.ps1
  ships desktop/ (exe + data/ + engine-host.exe + components/
  with yt-dlp.exe ffmpeg.exe ffprobe.exe). Smoke-tested: app
  launches and spawns the engine host.
- Browser integration installed: tools/release/install.ps1 writes
  the host manifest + %APPDATA% config + HKCU registration for
  Chrome/Edge; extension manifest carries a fixed `key` so the
  extension ID is deterministic (lfgb...amdo). Verified live:
  packaged native host accepted the origin, cold-launched the
  packaged engine host, ping → engineReachable: true.

## In Progress

- (none)

## Not Started

- (none — all M0–M15 milestones implemented)

## Blockers

- (none)

## Test Summary

- unit: core-domain 13, event-bus 1, persistence 4, media-api 5,
  update-api 18 (incl. 4 signature tests)
- application: scheduler 8 + url-refresh 11 (refresh→resume,
  same-file conflict, refresh failure, manual refreshSource)
- contract: adapter-brisk 8, adapter-ytdlp 6, adapter-ffmpeg 4
- integration: fixture server 12
- e2e: native host → engine host → brisk → disk (M5);
  EngineHostClient ↔ engine-host ↔ brisk → sha256 disk (3)
- desktop: flutter widget + helper tests 2
- media e2e: media.probe + media.enqueue over protocol v2 → real
  yt-dlp HLS download → ffmpeg mux → delivered file (engine-host)
- total: 83 dart tests + 2 flutter tests green
- real-binary: yt-dlp 2026.08.19 probe+download (HLS fixture,
  live YouTube), ffmpeg 9.0.1 mux (lavfi synth → ffprobe),
  full pipeline YouTube→mkv (tools/real-pipeline)
- HEAD-rejecting CDN: HEAD probe falls back to a 1-byte range GET
  (brisk patch 0003 + adapter fallback); verified live against
  xhscdn signed URL (HEAD→404, GET→206) — 59,465,115-byte file
  delivered to Downloads\FreeDM via packaged native host

## Known Limitations (for audit notes)

- Brisk dynamic segment-reuse can strand byte ranges when multiple
  connections die mid-flight simultaneously (upstream tree desync,
  "Failed to find node index"). Single-connection drop/retry/resume
  verified. Mitigation path: cap connections on flaky servers, or
  upstream fix.
- Brisk aggregate progress message reports totalReceivedBytes=0;
  adapter sums per-connection counts instead.
- Brisk has no speed limiter — FreeDM throttle layer required (M4).
- Bundles verify via Ed25519SignatureVerifier (fdmsig/1). The pinned
  key is the DEV key — a release signing key + rotation story is
  still a launch decision. Minisign interop not implemented.
- Real binaries verified: yt-dlp 2026.08.19 (probe + download),
  ffmpeg 9.0.1 (mux), full pipeline end to end, media E2E over
  protocol v2 against the local HLS fixture.

## Post-rename hardening (jjamIDM)

- Downloads stage into `<name>.part`; renamed to the final name only
  after assemble completes. Failed tasks drop the `.part` artifact
  (temp segments kept for retry), cancelled tasks remove both.
- `media` command now forwards browser-context headers (cookie/UA/
  referer) end-to-end: extension → native host (validated) →
  media.enqueue → MediaSelection.headers → resolver + yt-dlp
  downloader (`--add-headers`) + port gains `subtitleLangs`.
- Extension stores bounded (tasks 500 / captureFailed+doneNotified
  1000, insertion-order eviction). Popup probes `task.status` for
  active tasks and marks `known:false` entries "종료됨" with no
  controls — stale tasks can't be sent commands after restart.
- Removed stubs: `apps/updater`, `plugin-host`, native-host `list`
  command (hardcoded `[]`), related workspace/script references.
  `packages/update-api` + `packages/plugin-api` stay — real tested
  code, reserved for component updates/plugins.

## Feature round (options/queue/dialog/floating/media-pause)

- Browser path now runs the real DownloadScheduler: native host
  spawns engine-host with `--queue <dir> --max-concurrent N`
  (config keys `queueDir`, `maxConcurrent`). `task.create` parks
  (persisted, survives restart), `task.start` admits. Concurrency,
  priority, retry-with-backoff, restart recovery now apply to
  browser downloads (ADR-0006).
- Extension options page (`options_page`): capture include/exclude
  extension filters, type→subfolder routing (`mp4,mkv=비디오`),
  connection count, notifications toggle, start-dialog toggle,
  floating-button toggle.
- Download-start dialog: `chrome.windows.create` popup
  (`dialog.html`) with editable filename, folder dropdown
  (type folders + rule pick), connection count, 지금 받기 /
  나중에 받기 (parks via `start:false`) / 취소 (hands back to the
  browser, recapture-safe).
- Floating video button: `content.js` on all http(s) frames — a
  shadow-DOM chip over hovered <video>/<audio>; http(s) src → file
  download, blob/embedded → media pipeline on the page URL.
- "모든 링크" context menu: collects `a[href]` via content script
  (scripting fallback), filters to file-like URLs + user filters,
  dedupes, caps at 200, bulk-enqueues.
- Media pause/resume: `media.pause`/`media.resume` (v2 additive).
  Engine steps pause in place; yt-dlp component steps kill the
  process and resume from `.part` on resume; pause during
  resolve/mux lands at the next download-step boundary. Restart
  marks interrupted media tasks failed/cancelled.
- Host: `start` command, validated `subdir` under downloadDir,
  `start:false`, `maxConnections`, `priority`; pause/resume/cancel
  fall back to media.* for coordinator-owned tasks.
- Hardening (post-round debug sweep):
  - `DownloadEngine.isKnown` port — queue-mode event subscription
    polls it before attaching (engine.create may lag `downloading`);
    media engine-step resume uses it to prefer `resume` over
    re-`create` (a fresh create would re-probe an expired URL and
    reset engine-side item state).
  - Brisk patch 0005: `start` returns `Future` so callers can await
    isolate registration; adapter `started`/`wantPause` flags make
    pause/resume/cancel safe before start instead of crashing on
    the engine's null internal maps.
  - Dialog window X-close hands the download back to the browser
    and clears the pending request (no lost downloads, no leak).
  - Selected-links batch enqueues directly — a per-link dialog
    would open a window storm.
  - Host subscribes to task events before `task.start` so a fast
    completion can't be missed.
  - `media.recover()` runs on every host start, not queue mode
    only.
- Deferred (analysis done, not built): speed limiter (needs a
  vendored Brisk token-bucket patch), clipboard watch (needs a
  native-side poller — MV3 can't poll the clipboard).

## Reliability round (subscription replay / media persistence / shutdown drain)

- `media.remove` + `media.list` (protocol v2 additive): media tasks
  are persisted in `<dataDir>\media-tasks`; desktop merges them into
  the UI at startup (newer live state wins by `updatedAt`), and
  remove cancels active work then deletes the durable record so
  removed tasks can't resurface.
- Native host subscription replay: engine respawn drops every
  `task.subscribeEvents` — `ensure_engine` replays `subs`, terminal
  events prune it, and start/pause/resume/cancel re-subscribe
  idempotently first (queue-persisted tasks have no in-memory sub
  after a host restart — without this, their events never reach the
  browser).
- Shutdown ordering: server emits the `shutdown` ack then drains
  pending writes with a bounded flush; client waits 12s for exit
  (worst-case drain 2×5s) before killing; stdin EOF also flushes
  bounded. Scheduler `flush()` drains the debounced repo write
  chain — desktop calls it before engine shutdown on app exit.
- `JsonTaskRepository`: chained write queue, `.bak` fallback,
  per-line corrupt tolerance, and writeQueue surviving a failed
  write.
- Scheduler recovery rearms `retryWait` timers and restarts
  `urlExpired` tasks through `_refreshAndResume`.
- Browser engine data dir split: `install.ps1` passes
  `--data-dir <dataDir>\browser` so the browser-spawned engine and
  the desktop app never share one JSON task repository.
- Client hardening: `EngineHostClient` fails pending calls and
  closes task/media streams on host death; `_eventFromJson` maps
  queue-mode synthesized status frames (`status:'completed'` on a
  progress frame) to real terminal events; `enqueueMedia` forwards
  `headers`.

## Deep-audit round (lifecycle races / queue ownership / dispatch)

- Queue ownership lock: engine-host takes an exclusive
  `engine.lock` inside `--queue DIR` for its process lifetime — two
  browsers (Chrome + Edge native hosts) otherwise spawn engines
  that double-write `tasks.json` and re-dispatch the same segment
  temp files. A second instance exits with a clear error.
- Native host compensates orphaned parked tasks: a `download`
  command that fails after `task.create` (subscribe/start error or
  transport drop) issues a best-effort `task.cancel` on a respawned
  engine so the extension's browser fallback can't produce a
  duplicate download later.
- Scheduler stale-task guards: `_refreshAndResume` re-reads the
  task after the refresh await on both success and failure paths,
  and re-checks after `replaceSource`+`start` — a cancel landing in
  either window no longer resurrects or orphans the task. Refresh
  cycles count against `retryPolicy.maxAttempts` (a permanently
  dead URL can no longer loop refresh→start→403 forever).
- `pause()` covers every pre-dispatch/parked state: `created`,
  `resolving`, `ready`, `authRequired`, `urlExpired` transition to
  `paused`; `retryWait` pauses and disarms the backoff timer. New
  state-machine edges: `urlExpired→paused`, `created→failed`,
  `verifying→cancelled`, `postProcessing→cancelled`,
  `paused→downloadingAudio`, `ready→pausing`.
- Media coordinator: post-start terminal check in `_engineStep` —
  a cancel landing inside the create/start await no longer leaves
  an orphaned engine download writing into workDir.
- Engine-host RPC dispatch is concurrent (a slow `media.probe` no
  longer blocks pause/status); in-flight dispatches are drained
  with a 5 s bound on stdin EOF before the persistence flush.
- Brisk upstream patch 0006: request-header logging reduced to
  header names only — Cookie/Authorization values must not reach
  `<tempRoot>/<taskId>` logs (AGENTS.md rule 8). Registry now lists
  all six vendored patches.

## Environment notes

- OS: Windows (user machine). git 2.39, node 24, python 3.10 present.
- Dart SDK 3.13.4 vendored at `../.tools/dart-sdk` (outside repo, not committed).
- Rust 1.98.1 (gnu toolchain) installed — native-host builds.
- Flutter 3.47.4 vendored at `../.tools/flutter` (outside repo).
  Windows build needs Visual Studio "Desktop development with C++".
