# Contributing to FreeDM

## Before you code

1. Read `AGENTS.md` — the 14 mandatory rules are enforced by CI where possible.
2. Read the relevant ADR in `docs/adr/` before changing an architecture boundary.
3. Never vendor upstream code without provenance in `upstream-registry.yaml`.

## Dependency direction (enforced by `tools/architecture_test`)

```
UI → application → core-domain (ports) ← adapters
```

- `core-domain` may not import any `adapter-*` or upstream package.
- `application` may not import Brisk internals or spawn yt-dlp/FFmpeg.
- Provider registration happens only at composition roots (`apps/*`).

## Commits

- One milestone or logical feature per commit.
- `feat(<area>): <why>` conventional-commit style.
- Upstream version bumps and feature work go in separate commits/PRs.

## Tests

Every milestone ships with its tests. Do not merge with failing tests.
If an environment limitation blocks a test, document: why impossible, what
command was run, what alternative verification was done.
