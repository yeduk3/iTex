# 구현 결과 (Implementation) — Phase 0–4

> [05-validation-and-plan.md](05-validation-and-plan.md) 의 단계별 계획을 실제 코드로 구현한 결과.
> 모든 macOS 동작은 빌드 + 런타임 검증됨. iOS 컴파일 엔진(Tectonic)은 코드 완성 + macOS 정적 lib 빌드까지,
> iOS 크로스컴파일은 이 환경에 rustup 타깃이 없어 빌드 스크립트 + 문서로 제공(아래 §환경 한계).

## 한눈에

| Phase | 산출물 | 상태 |
|---|---|---|
| 0 | latexmk 백엔드 · draft fast-preview · PDFKit viewport 보존 | ✅ 빌드+검증 |
| 1 | SyncTeX forward/inverse(에디터↔PDF) · 이미지 프록시 캐시 | ✅ 빌드+검증 |
| 2 | `CompileBackend` 프로토콜 · warm 프리컴파일 `.fmt` 백엔드(pdflatex) | ✅ 빌드+검증 |
| 3 | Tectonic Rust FFI · `TectonicBackend`(iOS) · XCFramework 스크립트 | ✅ **macOS lib 빌드+FFI E2E 검증** / ⚠️ iOS 크로스컴파일만 rustup 필요 |
| 4 | `itex` CLI(PDF+`.synctex.gz`) · LaTeX Workshop/texlab/latexmk 설정 | ✅ 빌드+검증 |

## 검증 (실측)

shell 사전검증(68MB PNG 문서 기준):
- 전체 컴파일 5.6s, **draft 0.26s**(이미지 스킵), 프록시 다운스케일 후 PDF **69MB→1.3MB**.
- warm `.fmt`: 빌드 0.29s, 재사용 0.22s. `synctex view/edit` 좌표 파싱 OK.

`itex --selfcheck` (엔진 단위 런타임 검증) — **ALL PASS (8/8)**:
- `parseForward` rect + **Y-flip**(792−v−H) 정확 · `parseInverse` file+line
- latexmk → PDF + SyncTeX 생성 · **warm 백엔드** → PDF + 재사용 `.fmt` 빌드 · 이미지 프록시 축소

`itex compile` E2E (61MB 이미지 문서): xelatex 정상 3.5s+synctex · draft 0.44s(38KB) · `--downscale-preview` 61MB→5MB/1.3s.

빌드: iTex-macOS ✅, iTex-iOS ✅ (cross-platform), `itex` CLI ✅.

## 파일 맵

**엔진 (Sources/)**
- `CompileEngine.swift` — `CompileProfile`/`CompileResult`/`CompileBackend` 프로토콜, `Subprocess`(파이프 데드락 방지 드레이닝), `LatexmkBackend`(기본, `-usepretex` draft 주입), `PrecompiledFormatBackend`(warm, 줄패딩으로 synctex 줄번호 보존), `ImageProxyCache`(sips 다운스케일+content-hash 캐시).
- `SyncTeX.swift` — `synctex` CLI 래퍼. forward(line→PDF rect, Y-flip) / inverse(클릭→file:line). 72-dpi 좌표 사용(직접 파싱 안 함).
- `LaTeXCompiler.swift` — 코디네이터. 백엔드 선택(engine+profile), SyncTeX 상태(cursorLine/forwardHighlight/selectLineRequest, 토큰 디듀프), `forwardSearch()`/`inverseSearch()`. iOS는 `#elseif ITEX_TECTONIC`.
- `TectonicBackend.swift` — in-process Tectonic(`#if ITEX_TECTONIC`). iOS 유일 경로.
- `PDFPreviewView.swift` — viewport 보존 리로드(scale+destination 캡처/복원), forward 하이라이트 annotation, ⌘-클릭 inverse search.
- `LaTeXEditorView.swift` — cursorLine 보고(selection 변경), inverse 시 줄 선택/스크롤. `range(ofLine:)`.
- `EditorView.swift`/`ContentView.swift` — compiler 전달, ⌘J forward / ⌘B final.

**Tectonic FFI (tectonic-ffi/)** — `Cargo.toml`(tectonic 0.15, staticlib), `src/lib.rs`(2-fn C ABI), `include/itex_tectonic.h`, `module/module.modulemap`, `build-macos.sh`, `build-xcframework.sh`, `README.md`.

**CLI (cli/)** — `Package.swift`, `Sources/itex/{main,Shims,Selfcheck}.swift` + 엔진 심볼릭링크(단일 소스). latexmk 호환 플래그.

**연동 (integration/)** — `latex-workshop.settings.jsonc`, `latexmkrc`, `texlab.toml`, `README.md`.

## 프로파일 동작 (docs/04 §4.2)
- **FastPreview**(편집 디바운스): latexmk + `-usepretex` draft → 이미지 스킵, synctex 유지, cross-ref 근사.
- **FinalCompile**(⌘B): latexmk rerun-until-stable + biber, 풀해상도.
- **warm**(opt-in, pdflatex): `useWarmEngine=true` 시 `.fmt` 재사용(synctex는 latexmk 경로에서).

## Phase 3 Tectonic — 빌드 실측 (macOS 검증 완료)
`tectonic-ffi/build-macos.sh` → `libitex_tectonic.a` (~40MB), 심볼 `_itex_tectonic_compile`/`_itex_tectonic_free` export 확인. **C FFI 스모크 테스트로 실제 문서 컴파일 성공**: `itex_tectonic_compile(...) → PDF_BYTES=5110, "%PDF-"`. 즉 Rust FFI → Tectonic 엔진 → PDF 경로 E2E 동작.
빌드까지 거친 실제 이슈(모두 build-macos.sh 에 반영, 재현 가능):
1. tectonic 0.15.0 crates.io = build-rot(cranko 핀 + app_dirs2 드리프트) → **git tag 핀**으로 해결.
2. vendored harfbuzz build.rs 헤더복사 버그 → **`external-harfbuzz`**(brew harfbuzz 링크)로 우회.
3. `<harfbuzz/hb.h>` 못 찾음 → **CPATH** 에 brew include 추가.
4. icu4c@78 헤더가 C++17 요구 → **`CXXFLAGS=-std=c++17`**.

## 환경 한계 (정직)
- **iOS Tectonic 크로스컴파일만 미완**: 이 머신은 Homebrew rust(=no rustup) → `aarch64-apple-ios` 타깃 추가 불가. iOS XCFramework는 `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` 후 `build-xcframework.sh` 실행 필요. Tectonic은 순수 Rust+vendored C라 fork 없이 빌드 가능성 높으나 App Store entitlement 하 실증은 spike 필요(docs/05 §C). macOS 경로는 위처럼 완전 검증됨.
- **Tectonic hermetic 아님**: 첫 실행 시 TeXLive bundle 네트워크 fetch. iOS는 V2 driver + 로컬 bundle 동봉으로 전환 필요(TODO, tectonic-ffi/README).
- **이미지 라이브 프록시 치환**: `\graphicspath` 치환이 latexmk 하에서 불안정 → FastPreview는 draft 사용(편집 루프 문제 해결). 프록시는 CLI `--downscale-preview`(temp-dir)에서 동작. 라이브 에디터 치환은 follow-up(`ponytail:` 주석 표시).
- **warm + SyncTeX**: warm 백엔드는 synctex 생략(latexmk 경로가 제공). xelatex warm fidelity는 tex-fast-recompile 경로가 업그레이드 패스.
