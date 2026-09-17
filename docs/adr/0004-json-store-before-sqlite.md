# ADR 0004: JSON task store before SQLite

- Status: accepted
- Date: 2026-09-17
- Milestone: M4

## Context

The design doc specifies SQLite for the task database. `package:sqlite3`
on desktop Dart requires `sqlite3.dll` — a native binary that under our
own rules must be a *managed component* (pinned, hash-verified,
rollback-capable) delivered by the Component Manager (M12), not a
loose file committed to the repo.

## Decision

M4 ships `JsonTaskRepository`: a single-file JSON store implementing
the `TaskRepository` port owned by core-domain. Writes are serialized
through an internal queue and use temp-write + rename (with `.bak`
rotation on Windows, where rename cannot overwrite).

## Consequences

- M4 is unblocked without vendoring a native binary.
- The `TaskRepository` port makes the SQLite swap a drop-in adapter
  change later — no application/UI code touches storage details.
- Known limitation for audit: JSON flush is not fully atomic on
  Windows (delete+rename window); `.bak` mitigates. Credentials are
  unaffected — only `credential://`/`headers://` refs are persisted.
- Revisit at M12 when `sqlite3.dll` can be delivered as a managed
  component with provenance in `components.lock`.
