# FreeDM

FreeDM은 IDM(Internet Download Manager)급 UX를 목표로 하는 무료 오픈소스 다운로드 매니저 플랫폼이다.

핵심 설계 문장:

> **FreeDM은 특정 프로젝트의 개조판이 아니라 독립 Download Manager Platform이며,
> Brisk / yt-dlp / FFmpeg 등은 교체 가능한 Provider다.**

## Architecture (요약)

```
Browser Extension (MV3)
      │  Native Messaging v1
      ▼
freedm-native-host (Rust)
      │  Local IPC Protocol v1
      ▼
FreeDM Desktop / Stable Core (Dart)
      │  DownloadEngine Protocol v2 (media.* 추가)
      ▼
freedm-engine-host ── BriskAdapter ── pinned Brisk engine
      │
      ├─ yt-dlp.exe   (MediaResolver/Downloader provider)
      ├─ FFmpeg       (MediaMuxer provider)
      └─ plugin-host  (out-of-process plugins, reserved)
```

모든 외부 component는 `components/` 아래 versioned directory에 설치되고
atomic pointer로 활성화되며, 실패 시 이전 버전으로 rollback된다.

## 사용법 (release/freedm-rc)

1. `desktop/freedm_desktop.exe` 실행 — engine host와 미디어 도구
   (yt-dlp/FFmpeg)가 같은 폴더에서 자동 로드된다.
2. URL 입력 → 일반 파일은 Brisk 분할 다운로드, 미디어 페이지
   (YouTube 등)는 자동으로 yt-dlp 해석 + FFmpeg mux.
3. 브라우저 연동: `browser-extension/`을 개발자 모드로 로드하고
   `native-host-manifest.json`을 Chrome/Edge 네이티브 호스트로
   등록하면 다운로드 가로채기가 동작한다.

## Status

구현 상태는 `docs/IMPLEMENTATION_STATUS.md`를 본다.
아키텍처 결정은 `docs/adr/`를 본다.

## License

GPL-3.0-or-later. Third-party 라이선스는 `THIRD_PARTY_NOTICES.md` 참조.
