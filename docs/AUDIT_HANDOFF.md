# FreeDM RC — Audit Handoff (M15)

This document is the audit evidence bundle: provenance, verification
procedure, and known limitations. It must be regenerated at each RC.

## Component provenance

| Component | Upstream | Revision/Version | License | Distribution |
|---|---|---|---|---|
| engine.brisk | BrisklyDev/brisk_download_engine | `ec9e4f1` (v1.0.1) + patch queue | MIT | vendored `third_party/` |
| media.ytdlp | yt-dlp/yt-dlp | pinned per components.lock | Unlicense | github release asset |
| media.ffmpeg | BtbN/FFmpeg-Builds | pinned per components.lock | LGPL/GPL (build-dependent) | github release asset |
| native-host | this repo | src/ | GPL-3.0 | built `cargo build --release` |
| engine-host | this repo | apps/engine-host | GPL-3.0 | `dart compile exe` |
| extension | this repo | browser-extension/ | GPL-3.0 | unpacked MV3 |

Authoritative registry: `upstream-registry.yaml`. Pins:
`components.lock`. Patch queue: `third_party/brisk-engine/patches/`.

## Verification procedure (clean machine)

```powershell
# toolchain: Dart SDK 3.13+, Rust stable (gnu), Flutter 3.47+
# (Flutter only for the Windows desktop binary)
flutter pub get                      # workspace resolve
dart tools/architecture_test/check_imports.dart
bash tools/test_all.sh               # all package tests
cd native-host && cargo test && cargo build --release
python native-host/test/self_test.py
python native-host/test/e2e_engine.py   # browser→host→engine→disk
dart tools/upstream-watch/upstream_watch.dart
powershell -File tools/release/package.ps1
```

## Security boundaries exercised by tests

- Native host: frame-size cap, origin/extension allowlist, command
  allowlist, http(s)-only URLs, filename traversal rejection,
  control-character rejection, protocol-version check.
- Application: secrets never persisted (credentialRef/headersRef
  only); engine events → state machine → repo (engines never mutate).
- Components: sha256 verified before activation; atomic marker
  switch; pinned versions refuse updates; GC respects engine-affinity
  refs.
- Same-file validation on URL refresh: etag/lastModified/length/
  contentType conflict → task fails rather than corrupting output.

## Known limitations (must ship in release notes)

- Brisk multi-connection segment-reuse can strand ranges when several
  connections die mid-flight (upstream "Failed to find node index").
  Workaround shipped: drop/retry verified on single connection.
- Brisk has no speed limiter — policy is recorded, engine ignores it.
- Bundle signature verification is hash-only (Sha256OnlyVerifier);
  minisign/ed25519 verification is the release-blocking follow-up.
- Desktop Windows binary requires Visual Studio "Desktop development
  with C++" workload; not bundled in dev RC.
- Real yt-dlp/FFmpeg binaries not bundled; adapters verified via
  shims. Install via component manager when published.

## Evidence artifacts

- `docs/upstream-report.json` — latest upstream watch output.
- `release/freedm-rc/SHA256SUMS.json` — shipped-artifact hashes.
- CI: `.github/workflows/ci.yml` + `architecture.yml`.
