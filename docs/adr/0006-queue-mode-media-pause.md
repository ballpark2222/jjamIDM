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
6. **`DownloadEngine.isKnown`** — synchronous "does the engine still
   track this id" query. Queue-mode event subscription polls it
   before attaching (engine.create may not have run yet), and media
   engine-step resume uses it to pick `resume` over a fresh
   `create`+`start` (a re-create would re-probe a possibly-expired
   URL and reset in-memory item state).
7. **Brisk patch 0005** (`start` returns `Future`) + adapter
   `started`/`wantPause` guards — pause/resume/cancel issued before
   the engine isolate registers the task used to crash on null
   internal maps; a pre-start pause is now queued and applied the
   moment the task starts.
8. **Pause acknowledgement loop** — upstream silently drops a pause
   that arrives before connection channels exist (`sendToDownloadIsolates`
   rewrites it to `startInitial`; the `pauseOnFinalHandshake`
   deferral is dead code — the send is commented out). The adapter
   therefore re-sends pause until the engine reports a paused
   status (`pauseAcked`), gated on the first progress message which
   proves connection channels are live; `pauseEpoch` abandons a
   stale loop when resume/cancel supersedes it. The same
   retry-until-stopped applies to a cancel that raced `start()`.

   Follow-up hardening (same upstream quirks, three more cases):

   - **Stale paused reports**: `paused` in a progress message is a
     per-connection flag, so stragglers can be delivered after a
     resume (queued behind the start command) or satisfy a *new*
     pause's ack before it ever sends. The adapter gates paused
     handling on `expectPaused` and un-acks when running progress
     contradicts a paused report; the retry loop waits one settle
     beat before trusting an ack.
   - **Cancel in the pre-channel window**: `sendToDownloadIsolates`
     rewrites *any* command — `cancel` included — to `startInitial`
     while `connectionChannels` is empty. `cancel()` therefore
     re-sends until the engine's `Canceled` status removes the task.
   - **create() re-attach**: scheduler resume/restart recovery
     re-creates the adapter task; the event stream is carried over
     so existing subscribers (queue-mode `task.event` forwarding)
     aren't orphaned.

9. **`media.remove`** — deletes a media task's record (cancelling
   in-flight work first). Without it the desktop UI had no way to
   remove a media task: `pause`/`resume`/`remove` were routed to
   the download scheduler, which never saw `media.enqueue` tasks
   and threw `unknown task`; and even a routed cancel left the
   record in the media repo, where `listActive` (which includes
   `paused`) would resurface it as `failed` on the next host
   start. `DesktopController` now routes pause/resume/cancel/
   remove by `TaskKind.media` to the `media.*` family.
10. **Event-subscription replay (native host)** — subscriptions die
    with the engine process: a respawned engine recovered the
    queue but streamed nothing to the browser (popup froze, no
    completion notifications). The host tracks subscribed ids,
    replays `task.subscribeEvents` after every respawn, and prunes
    ids on terminal events. (`media.event` needs no subscription —
    the server broadcasts it unconditionally.) Queue persistence
    hardened alongside: `tasks.json.bak` fallback for the
    crash-mid-flush window, corrupt-store tolerance on open, and a
    write queue that survives a failed flush.
11. **`media.list`** (v2 additive) — durable snapshot of every media
    task the host tracks. `media.event` is broadcast-only: tasks
    recovered to a terminal state by `recover()` fired before any
    client could attach, so restored media tasks were invisible in
    the desktop UI. `DesktopController.loadExisting()` now merges
    `EngineHostClient.listMediaTasks()` into the task map; a v1 host
    or a media-less v2 host yields an empty list. Companion fixes:
    the engine-host binary constructs `EngineHostServer` (which
    subscribes to `media.changes`) before `media.recover()` so the
    recovery transitions are pushed too, and queue-mode
    `task.subscribeEvents` on an id the scheduler doesn't track now
    returns `taskNotFound` instead of registering a listener that
    can never match — the native host drops the id from its replay
    set on that error.
12. **Repo-only terminal records are removable** — `remove()` on
    both `DownloadScheduler` and `MediaDownloadCoordinator` used to
    fail/no-op for records restored from the repo but absent from
    memory (recover() only loads active states), so an old
    completed/failed task could never be deleted. Both now delete
    the repo record unconditionally.
13. **Shutdown drains persistence** — `engine.shutdown` previously
    exited while debounced/queued repo writes were still in flight,
    so a final `completed` could resurrect as `failed` on the next
    launch. Scheduler and coordinator track the last write
    (`_lastWrite`); the server's shutdown path flushes both with a
    bounded timeout, and `EngineHostClient.shutdown()` waits for
    the child's `exitCode` before falling back to `kill()`. The
    engine-host binary also exits on stdin EOF — a dead control
    plane used to leave an orphaned host writing shared segment
    temp files while the next launch's recovery re-dispatched the
    same tasks (double-writer window). The server additionally
    flushes stdout before `exit(0)` so the ack isn't dropped from
    the sink buffer.
14. **Recovery covers parked retry/expiry states** — `retryWait`
    and `urlExpired` are non-terminal but were invisible to
    recovery: the retry backoff timer is in-memory, and
    `urlExpired` wasn't in `listActive` at all. A crash in either
    state stranded the task forever (never retried, never
    refreshable — `refreshSource` only sees in-memory tasks).
    `listActive` now includes `urlExpired`, `recover()` re-arms the
    retry timer via `_scheduleRetry`, and urlExpired records re-run
    `_refreshAndResume` (failing honestly when no resolver exists).
15. **Dispatch failures retry; cancel-during-failing-start is safe** —
    an `engine.create`/`start` exception used to `_fail` instantly,
    skipping the retry policy that already treats
    `engineUnavailable` as retryable, and a cancel landing before
    the throw made `_fail` raise `InvalidTransitionError` on
    cancelled→failed. Both dispatch paths now route through
    `_failed` behind a terminal-state guard: transient spawn
    failures back off and retry; a cancelled task stays cancelled.
16. **App-exit durability** — the desktop never flushed on quit:
    `scheduler.dispose()` cancelled debounce timers and the engine
    host died on stdin EOF mid-write. `dispose()` now flushes
    first, `DesktopController.shutdown()` drains the scheduler and
    calls `EngineHostClient.shutdown()`, and the app answers
    `onExitRequested` only after both complete. Debounced progress
    writes and the `_refreshAndResume` upsert are chained into
    `_lastWrite` so `flush()` can't return while they are in
    flight.

## Consequences

- Browser-triggered downloads now get concurrency limits (default
  3), priority ordering, retry-with-backoff, persistence, and
  restart recovery — matching the desktop path's guarantees.
- Held ("나중에 받기") tasks persist in `%APPDATA%\jjamIDM\queue`.
- Pausing a media task mid-mux waits for the stage boundary —
  honest limitation, documented for the UI.
- Pause/cancel is safe at any point in a task's life — including
  the resolving/parked window — without engine-side crashes.
- The browser-spawned engine uses its own `--data-dir`
  (`<dataDir>\browser`) — sharing `media-tasks` with the desktop's
  engine put two process-local repository writers on one file.
- Extension task mirroring into `chrome.storage.local` is debounced
  (400 ms) — per-event writes could exhaust the write-ops quota.
