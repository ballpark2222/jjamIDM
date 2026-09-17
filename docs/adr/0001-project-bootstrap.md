# ADR-0001: Project bootstrap — repo layout, Dart workspace, language pins

- Status: accepted
- Date: 2026-09-17

## Context

FreeDM is specified (design doc v2.1) as an independent download-manager
platform: a stable Dart core, versioned port APIs, replaceable adapters,
an out-of-process engine host, a Rust native-messaging host, an MV3
browser extension, and a one-click component updater.

The dev machine has git/node/python but no Dart, Flutter, or Rust
toolchains installed.

## Decision

- Repo root: `freedm/` under the user's workspace; structure follows
  design doc §6 (apps/, packages/, browser/, test-server/, tools/, …).
- Dart packages are managed as a **pub workspace** from the repo root
  (`resolution: workspace` in each member) — one `dart pub get`, one
  dependency graph, easy cross-package refactor.
- Dart SDK 3.13.4 is vendored at `<workspace>/.tools/dart-sdk`,
  outside the repo, never committed. CI installs its own SDK.
- Component kinds follow design doc §4.1 (external binary / engine
  bundle / plugin / data bundle / app-bridge).
- Rust (native-host) and Flutter (desktop GUI) toolchains are deferred
  to their milestones (M5, M14) rather than installed up front.

## Alternatives

- Install full toolchains immediately — rejected: Flutter SDK is ~1 GB
  and unneeded until M14; per-milestone install keeps early steps fast.
- Single-package Dart repo — rejected: the dependency-boundary rules
  (core must not see adapters) need real package boundaries to be
  mechanically enforceable.

## Consequences

- `dart pub get` at repo root resolves all packages.
- `tools/test_all.sh` iterates workspace packages for CI parity.

## Rollback strategy

Directory names can shift as long as dependency boundaries hold;
workspace members can be moved with path edits only.
