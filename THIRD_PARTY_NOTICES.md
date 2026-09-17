# Third-Party Notices

FreeDM incorporates or integrates the following third-party components.
Exact pinned revisions are recorded in `components.lock` and
`upstream-registry.yaml`. Per-component detail lives in `docs/licenses/`.

## Runtime components

| Component | Upstream | License | Usage |
|---|---|---|---|
| brisk_download_engine | github.com/BrisklyDev/brisk_download_engine | MIT | HTTP download engine (vendored, Engine Host bundle) |
| yt-dlp | github.com/yt-dlp/yt-dlp | Unlicense | MediaResolver provider (external executable) |
| FFmpeg | ffmpeg.org / BtbN builds | LGPL-2.1+/GPL-2+ (build dependent) | MediaMuxer provider (external executable) |

FFmpeg license obligations depend on the exact build options of the
distributed artifact; record the chosen distribution's license before
shipping (`docs/licenses/ffmpeg.md`).

## Reference-only projects (no code included)

- AB Download Manager (Apache-2.0) — browser-integration UX reference
- Brisk browser extension — interception UX reference
- Brisk monorepo (GPL-3.0) — newer engine lineage, see ADR-0002
