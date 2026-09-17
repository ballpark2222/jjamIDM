# ADR-0006: Browser queue mode + media pause/resume (protocol v2 additive)

## Status

Accepted — implemented.

## Context

The browser native host used to call `task.create` + `task.start`
directly, bypassing the application `DownloadScheduler` entirely:
no concurrency cap, no priority, no retry policy, no persistence,
no restart recovery. Media tasks additionally supported only
`cancel` — never `pause`/`resume`.

## Decision (additive to Protocol v2 — no version bump)

Backward-compatible additions only; existing clients are unaffected:

1. **`task.create` `priority` param** (optional int) — scheduler
   queue ordering in queue mode.
2. **engine-host `--queue DIR` / `--max-concurrent N` flags** —
   when present, `task.*` calls route through `DownloadScheduler`
   (repository at DIR, so held/in-flight tasks survive restarts).
   `task.create` enqueues with `autoStart:false` (parked);
   `task.start` admits. Browser native host always launches the
   engine this way; the desktop app keeps the passthrough (it has
   its own scheduler).
3. **`media.pause` / `media.resume`** — media download-step
   pausing. Engine-backed steps pause via the engine; component
   (yt-dlp) steps are killed and resume from `.part` artifacts by
   re-invoking with identical args. Resolve/mux/subtitle stages are
   not interruptible; a pause requested there lands at the next
   download-step boundary. Restart recovery marks interrupted media
   tasks failed/cancelled (in-memory run state can't be rebuilt).
4. **native host**: `start` command (admits parked tasks),
   `subdir` (validated relative path under `downloadDir`),
   `start:false` on `download` (park), `maxConnections`,
   `priority`. `pause`/`resume`/`cancel` fall back to
   `media.<cmd>` when `task.*` rejects the id.
5. **`ComponentDownloader` port** gains optional
   `CancellationToken cancel` — downloader returns
   `cancelledExitCode (-100)` keeping partial artifacts.

## Consequences

- Browser-triggered downloads now get concurrency limits (default
  3), priority ordering, retry-with-backoff, persistence, and
  restart recovery — matching the desktop path's guarantees.
- Held ("나중에 받기") tasks persist in `%APPDATA%\jjamIDM\queue`.
- Pausing a media task mid-mux waits for the stage boundary —
  honest limitation, documented for the UI.
