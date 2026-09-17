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
17. **`pageUrl` rides the wire (additive)** — the browser captures
    the page a download came from, but `DownloadRequestDto` never
    carried it, so `DownloadSource.originalPageUrl` was always null
    and URL-refresh resolvers had nothing to re-fetch on signed-URL
    expiry. The DTO gained an optional `pageUrl` field (old peers
    omit it → null; additive, no version bump per this ADR's
    convention), the native host forwards the validated value, and
    the server's `toDomain` maps it to `originalPageUrl`.
18. **Per-task media work dirs** — `media.enqueue`'s default
    `workDir` (`<tempRoot>/media`) was shared by every task, so two
    downloads resolving to the same title wrote one output/.part
    concurrently. The coordinator now namespaces each run under
    `workDir/<taskId>`; mux/attach steps resolve relative names
    against it.
19. **Container-correct subtitle attach** — `attachSubtitles`
    forced a `.mp4` name and `-c:s mov_text` for any input; an mkv
    input produced a mislabeled file ffmpeg may reject. The output
    keeps the input's extension and the subtitle codec follows the
    container (`srt` for mkv, `webvtt` for webm, `mov_text` else).
20. **Process/arg hygiene** — `--max-concurrent` is clamped to
    1..64 (0/negative stalled the queue silently); the `.tools`
    ancestor walk probed `<d>/../.tools` twice and never `<d>/.tools`
    (a run rooted at the toolchain's own dir missed it); the media
    coordinator's workDir mkdir moved inside the run's try so an
    unwritable path fails the task instead of stranding it in
    `created`; the native host's shutdown grace for engine-host was
    raised 2s→12s to cover the server's worst-case 2×5s persistence
    drain; and the server's dispatch maps `FormatException`/
    `TypeError` (missing or mistyped params) to `badRequest` instead
    of a generic engine error.
21. **Manifest URLs route to the media pipeline** — a bare
    `.m3u8`/`.mpd` URL classified `directMedia` and went to the file
    engine, which saved playlist text. The desktop controller now
    sends manifests through `media.enqueue` when the pipeline is
    configured (`MediaUrlClassifier.isManifest`); without media
    support the file path remains as an honest fallback.
22. **Vendored patch 0006 — header-name-only request logging** —
    `base_http_download_connection.dart` logged the full request
    header map, which includes caller-supplied `Cookie` and
    `Authorization` values (AGENTS.md rule 8 forbids token logging).
    The vendored file now logs header names only; the change ships
    as `third_party/brisk-engine/patches/0006-redact-request-header
    -log.patch` so upstream rebases re-apply it.
23. **Progressive media fetches the format URL, not the page** —
    `YtDlpResolver.plan` built `EngineDownloadStep(url:
    selection.pageUrl)`, so a direct progressive download saved the
    HTML watch page under an `.mp4` name. `MediaFormat` now carries
    the resolver-emitted `url` (the signed CDN stream); the engine
    step uses it, and a format with no resolved URL falls back to
    the yt-dlp component step rather than fetching the page.
    `media.probe` surfaces `url` additively.
24. **Upstream engine statics are reaped on terminal status** —
    Brisk never removes `DownloadEngine.engineIsolates /
    engineChannels / downloadItems`; each finished download left an
    isolate with four periodic timers alive for the host's lifetime.
    The adapter kills the isolate and drops the map entries when a
    task reaches completed/canceled/failed — a retry re-runs
    create()+start(), and partial-file resume lives in the temp
    segment files, not the isolate.
25. **Client survives malformed stdout frames** — a stray non-JSON
    line on the host's stdout threw inside the client's decode
    `.map`, whose stream error path runs the same `_hostGone` used
    for process death — one bad frame killed every in-flight call.
    Decode failures now drop the line.
26. **Dead-server stall — handled pre-first-byte, limited after** —
    upstream's connection-reset timer stops retrying once
    `maxConnectionRetryCount` is exhausted but emits no `failed`
    status (http_download_engine.dart:152); a download whose server
    never answers stayed `connecting` forever. The adapter arms a
    `stallWatchdog` (bounded by retryTimeout × maxRetries) that
    fails the task `engineUnavailable` — retryable through the
    scheduler — when zero bytes arrive; progress, pause, and any
    terminal event disarm it. A mid-download stall after the first
    byte still relies on upstream reset machinery and can outlive
    the budget on a half-dead link — that residual case is a
    recorded limitation, not silently trusted.
27. **Same-uid re-create is not a cancel target** — the post-start
    zombie-kill loop now breaks if the id reappears in `_tasks`
    mid-loop, so a scheduler retry can't be cancelled by the loop
    cleaning up the previous incarnation.

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
- Media artifacts accumulate under `<tempRoot>/media/<taskId>` — a
  temp cleaner owns reclamation; `remove()` still only drops the
  record.
