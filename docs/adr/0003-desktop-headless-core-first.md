# ADR-0003: Desktop = headless control plane first, Flutter GUI deferred

- Status: accepted
- Date: 2026-09-17

## Context

Design doc targets Flutter for the desktop UI (M14). The dev machine has
no Flutter SDK (~1 GB install). Meanwhile every earlier milestone —
engine host, queue, persistence, native host, extension, component
manager — needs a running **control plane** process to talk to, not a GUI.

## Decision

- `apps/desktop` is implemented first as `freedm_core` — a headless
  Dart executable that owns the Stable Core (state machine, queue,
  persistence, component manager) and exposes the versioned local IPC
  that native-host and a future GUI both use.
- The Flutter GUI is added at M14 as a thin client over the same IPC;
  the control plane code does not move.

## Alternatives

- Install Flutter now — rejected: download size vs. zero use until M14.
- Dart + web UI — rejected as primary: violates the specified stack;
  may still ship as an optional diagnostic surface if cheap.

## Consequences

- IPC protocol must be correct early (it is already a versioned
  contract in the design), so this order actually de-risks M14.
- Cold-start path (extension → native-host → spawn desktop) launches a
  console process; hidden-window packaging is a release concern.

## Rollback strategy

The GUI becomes the desktop entry point later; the headless binary stays
useful for CI/E2E regardless — no code thrown away.
