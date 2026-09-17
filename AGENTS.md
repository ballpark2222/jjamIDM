# jjamIDM — AGENTS.md

jjamIDM is an independent open-source download manager platform.
Brisk / yt-dlp / FFmpeg are **replaceable providers**, not the product core.

## Mandatory rules

1. core-domain에서 adapter/provider implementation import 금지.
2. UI에서 external binary 직접 실행 금지.
3. Brisk upstream source 직접 수정 금지. 불가피한 경우 patch 파일과 ADR 필요.
4. yt-dlp/FFmpeg 명령은 각 adapter만 생성 가능.
5. upstream update와 기능 개발을 동일 PR에 섞지 않음.
6. components.lock은 compatibility test 없이 갱신 금지.
7. Task state transition은 core state machine을 통해서만 수행.
8. Cookie/Authorization/token 로그 출력 금지.
9. protocol/API schema 변경 시 versioning 및 migration 필수.
10. 테스트를 삭제하거나 약화해서 통과시키지 않음.
11. 실패 테스트를 skip 처리하기 전에 원인 문서화 필요.
12. 새 외부 dependency 도입 전 license/security/updateability 검토.
13. 구현 워커는 최종 품질 승인 권한 없음.
14. 최종 handoff에 외부 감사용 evidence를 남김.

## Layout

- `apps/` — desktop, engine-host, native-host (Rust)
- `packages/` — Dart packages: core-domain, application, *-api ports, adapter-*
- `third_party/` — read-only vendored upstream snapshots + `patches/`
- `browser/extension/` — TypeScript MV3 extension
- `test-server/` — deterministic local HTTP fixture server
- `component-registry/` — channels + schemas
- `docs/adr/` — architecture decision records
- `docs/audit/` — external-audit handoff evidence
- `tools/` — repo tooling (architecture test, component tools)

## Commands

```bash
dart pub get                        # workspace resolution (repo root)
dart test                           # per package; or:
tools/test_all.sh                   # run every package test suite
dart run tools/architecture_test/check_imports.dart   # dependency boundary check
```

Dev toolchain (Dart SDK) lives in `../.tools/dart-sdk` outside the repo and is
never committed.

## Contracts (versioned)

- DownloadEngine Protocol v1 — `packages/engine-protocol`
- Browser ↔ Native Host Protocol v1 — `packages/browser-api`
- Component Manifest Schema — `component-registry/`

Any schema change requires a version bump + migration note in `docs/adr/`.
