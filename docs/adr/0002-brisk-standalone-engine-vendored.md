# ADR-0002: Brisk engine — standalone MIT repo vendored, not monorepo git-dep

- Status: accepted
- Date: 2026-09-17

## Context

Design doc §3.1 prefers pinning `brisk_download_engine/` inside the
Brisk monorepo (GPL-3.0) via a git path dependency, with a vendored
snapshot as fallback.

Upstream investigation on 2026-09-17 found:

- Monorepo `brisk_download_engine/pubspec.yaml` depends on
  `path_provider` (Flutter plugin) and `rhttp` (Rust-backed HTTP client
  built via cargokit). Neither resolves under a pure `dart` SDK, so an
  engine-host **Dart CLI executable** cannot `pub get` it.
- Standalone `BrisklyDev/brisk_download_engine` (MIT, v1.0.1,
  last push 2024-12-12) declares `path_provider` too — but it is a
  **dead dependency**: zero imports of `path_provider` exist in
  `lib/`, `example/`, or `test/`. Its real deps (`http`, `stream_channel`,
  `dartx`, `uuid`, `path`) are pure Dart.

## Decision

- Vendor `BrisklyDev/brisk_download_engine` at a pinned commit into
  `third_party/brisk-engine/<sha>/` (read-only snapshot, MIT).
- Apply one minimal patch queue file:
  `third_party/brisk-engine/patches/0001-remove-dead-path-provider-dep.patch`
  — deletes the unused `path_provider`/`encrypt`-era dependencies from
  its pubspec so the vendored package resolves under standalone Dart.
- All FreeDM access goes through `packages/adapter-brisk` inside
  `apps/engine-host`. Desktop/core never import engine internals.
- Recorded in `upstream-registry.yaml` + `components.lock` with full
  provenance (repo, revision, license, patches).

## Alternatives

- Monorepo git path dep — rejected for now: unrunnable under pure Dart
  SDK (Flutter plugin deps); revisitable when the integration-bundle CI
  builds engine-host with Flutter tooling.
- Own HTTP engine — rejected as v1 default: Brisk provides segmented
  downloads, dynamic connections, and pause/resume that are costly to
  re-derive; keeping it behind DownloadEngine Protocol v1 preserves the
  swap path.

## Consequences

- Engine is older (2024-12) than monorepo tip; feature delta (e.g.
  rhttp transport, recent fixes) is deferred until the Engine Bundle CI
  pipeline (M13) can build the monorepo lineage.
- License posture: MIT engine vendored → notices in
  THIRD_PARTY_NOTICES.md; no GPL linkage needed for v1 builds.

## Rollback strategy

Swap `third_party/brisk-engine` snapshot or switch the adapter's
engine source; only `adapter-brisk` + engine-host glue change.
