# Audit evidence — media adapters + engine lifecycle round

Scope: `adapter-ytdlp`, `adapter-ffmpeg`, `adapter-brisk`,
`engine-host` client/server, `media-api`, `application`,
`native-host`, vendored Brisk patch 0006.

## Findings fixed

| # | Defect | Evidence |
|---|--------|----------|
| 1 | `YtDlpResolver.plan` emitted `EngineDownloadStep(url: pageUrl)` — progressive media downloads saved the HTML watch page as `.mp4` | `MediaFormat.url` added; resolver parses `m['url']`; plan uses `video.url!`, falls back to component step when absent. Tests: `fetches the resolved format url`, `without a resolved url falls back` |
| 2 | `FfmpegMuxer.mux` ignored `workDir` — bare input/output names resolved against the host CWD; returned `outputPath` was not the real file | `_resolve`/`_isAbs` join relative names to workDir and return the absolute output. Tests: `resolves bare inputs/output against workDir`, `leaves absolute paths untouched` |
| 3 | `-c:s mov_text` forced for every container — mkv rejects it | `_subCodecFor`: mkv→srt, webm→webvtt, else mov_text; output keeps input ext. Test: `container-legal subtitle codec` |
| 4 | Upstream `engineIsolates/engineChannels/downloadItems` never freed — one isolate + 4 timers leaked per download | `_reapUpstream` on completed/canceled/failed + stall-timeout path. Test: `statics are reaped on completion` |
| 5 | Post-start zombie-kill loop could cancel a same-uid re-create | identity check `!_tasks.containsKey` breaks the loop |
| 6 | One malformed stdout line threw in client `.map` → `_hostGone` killed all calls | decode failures drop the line |
| 7 | Dead server stalled `connecting` forever — upstream never emits `failed` after retries exhaust | `stallWatchdog` fails pre-first-byte tasks `engineUnavailable` (retryable). Mid-download residual stall documented in ADR-0006 item 26 |
| 8 | Queued-task pause was a silent no-op; `paused` didn't free the slot; `urlExpired` refresh looped without retry budget | scheduler + state-machine transitions (`created/resolving/ready→paused`, `ready→pausing`, `downloadingAudio→downloadingVideo`); `_pump()` on pause-ack; refresh shares retry budget |
| 9 | `media.enqueue` shared one flat workDir — same-title tasks collided on `.part`/output files | per-task `workDir/<taskId>`; `_deliver` picks `name (N).ext` on collision; mkdir inside try |
| 10 | `pageUrl` never crossed the wire — `originalPageUrl` was always null → URL-refresh had nothing to re-fetch | additive DTO field + native-host forward + server mapping (ADR-0006 item 17) |
| 11 | `.m3u8`/`.mpd` URLs classified `directMedia` → engine saved playlist text | `MediaUrlClassifier.isManifest` + desktop routes manifests to `media.enqueue` (item 21) |
| 12 | Vendored Brisk logged full request headers incl. Cookie/Authorization (rule 8 violation) | patch `0006-redact-request-header-log` — header names only; registered in `upstream-registry.yaml` |
| 13 | Native host: failed post-`task.create` commands left parked queue tasks → browser fallback could double-download | `compensate_created` respawns engine + cancels the id; shutdown grace 2s→12s covers 2×5s drain |

## Verification

- `tools/test_all.sh` — all suites green (adapter-brisk 16/16,
  adapter-ffmpeg 7/7, adapter-ytdlp 8/8, application 47/47,
  core-domain 13/13, engine-host 13/13 incl. real-binary media e2e,
  persistence 7/7, desktop, test-server, update-api, event-bus,
  media-api).
- `dart run tools/architecture_test/check_imports.dart` — OK.
- `dart analyze` — 0 errors/warnings (info lints only).
- `cargo check` (native-host) — clean.
- No vendored source edit outside the registered patch mechanism.
