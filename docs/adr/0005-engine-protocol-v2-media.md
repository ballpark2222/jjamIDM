# ADR 0005: Engine Protocol v2 — media.* over engine-host

## Status
Accepted

## Context
The desktop UI must never spawn external processes or import
adapters (architecture rules). The media pipeline
(yt-dlp resolve/download, FFmpeg mux) therefore needs a host
process. `plugin-host` was scaffolded empty; engine-host already is
a spawned worker speaking NDJSON-RPC with the control plane.

## Decision
Engine Protocol v2 extends v1 **additively**: `media.probe`,
`media.enqueue`, `media.cancel` plus `media.event` notifications
carrying TaskCodec-encoded DownloadTask snapshots. The coordinator
(MediaDownloadCoordinator) runs inside engine-host with the yt-dlp
and FFmpeg adapters; the desktop stays port-only.

- `supportedVersions = [1, 2]`; v1 clients work unchanged.
- Media binaries resolved via `--ytdlp`/`--ffmpeg`, env vars, then
  `<exeDir>/components/` (packaged) → repo `.tools/` (dev).
- `MediaDownloadCoordinator` now delivers the final artifact into
  the task's `targetDirectory` (was: left in workDir — bug fixed).

## Consequences
- plugin-host remains reserved for third-party plugins; the media
  pipeline is a first-class engine capability, not a plugin.
- New media methods are additive; no migration needed for v1
  callers.
