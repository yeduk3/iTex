# 04. 추천 아키텍처 & 확장성 (개선 + VSCode 연동 검증)

> iTex 의 단일 `buildPDF` 를, 여러 OSS 백엔드를 갖는 protocol + 프로파일 분리 + SyncTeX 오버레이로 교체한다.
> **설계 원칙: iTex 는 오케스트레이션 + glue 만 쓴다. 타입세팅·의존성 추적·sync 파싱은 전부 OSS 에 위임.**

---

## 4.0 레이어 그림

```
┌────────────────────────────────────────────────────────────────────┐
│  SwiftUI editor (LaTeXEditorView)  ──edit──▶ debounce (idle 기반)   │
└───────────────┬──────────────────────────────────────┬─────────────┘
                │ scheduleCompile(source, profile)      │ forwardSearch(line)
                ▼                                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  CompileCoordinator  (LaTeXCompiler 대체)                          │
│   • 프로파일 선택 (FastPreview | FinalCompile)                      │
│   • figure-cache 매니저 (content-hash → cached PDF)                 │
│   • 이미지 프록시/사전 스케일 캐시                                  │
│   • SyncTeXIndex (libsynctex)                                       │
└───────────────┬───────────────────────────────────────┬────────────┘
        protocol │ CompileBackend                        │
                 ▼                                        ▼
   ┌──────────────────────────┐            ┌──────────────────────────┐
   │ macOS 백엔드             │            │ iOS 백엔드               │
   │  A. latexmkBackend       │            │  Tectonic (in-proc, FFI) │
   │     (subprocess, 기본)   │            │   + 동봉 로컬 bundle     │
   │  B. warmEngineBackend    │            │   [fallback: SwiftLaTeX  │
   │     (tex-fast-recompile) │            │    WASM in WKWebView]    │
   │  C. tectonicBackend      │            └──────────────────────────┘
   │     (in-proc FFI, 공유)  │
   └──────────────────────────┘
                 │ foo.pdf + foo.synctex.gz 출력
                 ▼
┌────────────────────────────────────────────────────────────────────┐
│  PDFPreviewView (PDFKit) — viewport 보존 리로드                    │
│   • scaleFactor + 보이는 PDFDestination 캡처                       │
│   • 새 PDFDocument 세팅                                            │
│   • scale + destination 복원; SyncTeX 하이라이트 오버레이          │
│   • inverse search: PDFView 클릭 → libsynctex edit-query → 에디터  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 4.1 백엔드 프로토콜 (새로 만드는 유일한 추상화)

`LaTeXCompiler.buildPDF` 본문을 아래로 교체:

```swift
protocol CompileBackend {
    func compile(source: String, rootURL: URL?, profile: CompileProfile) async throws -> CompileResult
    // CompileResult { pdfURL, synctexURL?, log }
}
```

- **macOS 기본 = `LatexmkBackend`**: `latexmk -synctex=1 -interaction=nonstopmode -file-line-error -pdf -outdir=… <root>` spawn. 올바른 rerun + biber + SyncTeX(C4·C5 해결)을 ~10줄로, `LaTeXCompiler.swift:74-101` 교체.
- **macOS fast path = `WarmEngineBackend`**: tex-fast-recompile(또는 pre-warm-preamble 트릭의 네이티브 재구현)을 구동해 xelatex 호환 warm 재컴파일(C1+C2). label/citation 변경 시 full latexmk pass 로 fallback(정확성).
- **크로스플랫폼 코어 = `TectonicBackend`**: `libtectonic_ffi` 를 C-FFI 로 링크. **iOS 에서 유일하게 쓸 수 있는 백엔드**이자 macOS warm in-process 옵션. V2 `ProcessingSessionBuilder` 를 동봉 로컬 bundle + 앱 캐시 디렉터리의 `format_cache_path` 로 호출.

> ⚠️ `protocol CompileBackend` 가 한 개 구현일 땐 over-abstraction 이다. **3개 백엔드(latexmk/warm/Tectonic)가 실재할 때** 도입할 것. Phase 0~1 동안은 `LaTeXCompiler` 안에 직접 두고, Phase 2(warm engine)에서 두 번째 구현이 생길 때 protocol 추출.

---

## 4.2 Fast Preview 프로파일 vs Final Compile 프로파일

| | **Fast Preview** (편집 루프) | **Final Compile** (export / 명시 빌드) |
|---|---|---|
| 트리거 | 편집 후 idle-debounce (~500–800ms 유지) | 명시 "Build" / export |
| 이미지 | **draft 모드** 주입, 또는 externalized/프록시 캐시 | 풀해상도, 실제 임베드 |
| Rerun | warm 단일 pass; biber 생략 | latexmk rerun-until-stable + biber |
| Figure | 캐시 PDF 재사용(TikZ external/standalone) | 바뀐 figure 풀해상도 재빌드 |
| 엔진 | warm xelatex(tex-fast-recompile) 또는 Tectonic | latexmk + xelatex(macOS) / Tectonic(iOS) |
| SyncTeX | on (`-synctex=1`) | on |
| 목표 | 최저 edit-to-preview 지연; cross-ref *근사* | 바이트 정확, 올바른 번호 |

프로파일 분리가 "real-time preview" 에 대한 정직한 답이다: fast 는 cross-ref 정확성을 지연과 맞바꾸고, final 은 정확성을 보장한다. **UI 에 "draft preview" 상태를 표시**해, final 빌드 전까지 번호가 근사임을 사용자가 알게 할 것.

---

## 4.3 SyncTeX 를 SwiftUI 에디터 + PDFKit 에 배선

1. **빌드 플래그**: 모든 백엔드가 `-synctex=1` 출력(latexmk/Tectonic 둘 다 지원).
2. **파서**: `synctex_parser.c`/`.h` 를 *두 타깃 모두*에 벤더링(순수 C, subprocess 없음 → iOS 동작). bridging header 로 Swift 노출. ([CTAN synctex-parser](https://ctan.org/pkg/synctex-parser))
3. **Forward (에디터 → PDF)**: 커서 이동/커맨드 시 `synctex_display_query(scanner, file, line, col)` 호출, 결과 노드 순회, `synctex_node_visible_h/v/width/height`(이미 72-dpi) 읽기, **PDFKit 용 Y flip**, `PDFView` 페이지 오버레이로 하이라이트 사각형 그리기, `go(to: PDFDestination)`.
4. **Inverse (PDF 클릭 → 에디터)**: `PDFView` 클릭 캡처 → 페이지 좌표 변환(Y flip back) → `synctex_edit_query(scanner, page, x, y)` → 입력 파일 + 라인 읽기 → SwiftUI 에디터 selection 이동.
5. **Viewport 보존 (C7 해결)**: `PDFPreviewView.updateNSView`/`updateUIView`(`PDFPreviewView.swift:40-42`, `:57-59`)를, 새 `PDFDocument` 할당 **전에** `view.scaleFactor` + 현재 `PDFDestination` 을 **캡처**하고 다시 복원하도록 재작성 → 보이는 페이지만 재래스터화, 스크롤/줌 보존(PDF.js lazy-render 모델 미러). ([PDF.js #7391](https://github.com/mozilla/pdf.js/issues/7391))
6. **Atomic swap**: PDF 를 temp 경로에 쓰고 원자적 교체 → PDFKit 이 반쯤 쓰인 파일을 절대 안 읽음(latexmk `$pvc_view_file_via_temporary` 패턴).

> SyncTeX 구현 함정(검증에서 확인): 좌표 단위는 small-points×Unit 이지 raw sp 아님 → `synctex_node_visible_h/v`(72-dpi float) 사용, 직접 `/65536` 금지. `f`(form) 레코드는 line-tagged 아님. 자세히 [부록 SyncTeX 항목](appendix-sources-and-verdicts.md).

---

## 4.4 iOS 특이사항

- **trimmed 로컬 Tectonic bundle**(TeXLive 부분집합)을 앱 Resources 에 동봉 + 쓰기 가능 캐시 디렉터리. `TECTONIC_CACHE_DIR` 설정 / 로컬 `Bundle` 전달 → 네트워크 불필요. Tectonic 의 관리 작업 디렉터리에서 `\includegraphics` 상대경로 해석 검증(iTex 는 현재 compile-in-source-dir 에 의존, `LaTeXCompiler.swift:55-63`).
- texlab 보완은 macOS 전용(subprocess, `TexLabClient.swift` 가 `#if os(macOS)`). iOS 에선 in-process 소스에서 보완을 받거나 비활성화.
- iOS 의 Tectonic-FFI 가 너무 무겁거나 위험하면 **WKWebView 의 SwiftLaTeX-WASM** 으로 fallback — 단 AGPL 선클리어.

---

## 4.5 확장성 — VSCode 연동 경로

사용자가 가장 좋았던 환경은 VSCode 의 LaTeX extension. 가장 싸고 도달범위 넓은 통합은 **extension fork 가 아니라, iTex 엔진을 latexmk/tectonic 호환 CLI 로 노출**하는 것.

### 통합 사다리 (낮은 노력 → 높은 노력)

1. **CLI 출하** — 플래그/출력이 latexmk/tectonic 을 미러: `-synctex=1`, `-outdir`/`%OUTDIR%`, `nonstopmode` 수용, **PDF 와 `.synctex.gz` 를 out 디렉터리에 둘 다 emit**. **LaTeX Workshop** 의 `latex-workshop.latex.tools` + `.recipes` 항목으로, **texlab** 의 `build.executable`/`build.args` 로 그대로 들어감 — *extension 코드 0*. Tectonic 이 문서화된 선례. ([LaTeX Workshop Compile wiki](https://github.com/James-Yu/LaTeX-Workshop/wiki/Compile), [Tectonic recipe](https://github.com/tectonic-typesetting/tectonic/discussions/1181))
   ```jsonc
   "latex-workshop.latex.tools": [
     { "name": "itex", "command": "itex",
       "args": ["compile", "--synctex", "-outdir=%OUTDIR%", "%DOC%"] }],
   "latex-workshop.latex.recipes": [{ "name": "iTex", "tools": ["itex"] }]
   ```
   recipe/tool 형태는 LaTeX Workshop `package.json` 스키마로 검증됨: tool 은 정확히 `{name, command, args?, env?, cwd?}`, recipe 는 tool *이름*을 참조, default recipe 는 `"first"`.
2. **`.latexmkrc` 스니펫** — iTex 를 latexmk 엔진으로 설정(`$pdflatex`/`$pdf_mode`) → latexmk 를 기본으로 쓰는 모든 에디터 프리셋과 즉시 호환, 에디터 설정 무수정. ([latexmk](https://ctan.org/pkg/latexmk))
3. **LSP/빌드서버 래퍼** (texlab 식 `textDocument/build`) — 크로스에디터(Neovim/Emacs/Sublime) 도달, daemon/warm 파이프라인의 자연스러운 집. clean-room 으로 짓거나 texlab fork — 단 **texlab 은 GPL-3.0**. ([texlab](https://github.com/latex-lsp/texlab))
4. **전용 VSCode extension** — PDF.js + WebSocket live-refresh 채널 재사용으로 진짜 on-type 미리보기. 최고 제어, 최고 비용.

### 정직한 fork-vs-extend 판단
- **LaTeX Workshop fork 하지 말 것** (MIT 라 가능은 하나, ~6,597 커밋·12.2k 스타 코드베이스의 PDF.js viewer/SyncTeX/intellisense 를 물려받아 유지보수하게 됨). ([repo](https://github.com/James-Yu/LaTeX-Workshop))
- **할 것**: 먼저 CLI(사다리 1–2) 출하 — 설정 변경만으로 LaTeX Workshop *과* texlab 사용자 모두 도달. Tectonic 이 바로 이 경로를 입증.
- **최고 레버리지 요건**: **SyncTeX 를 1급 엔진 출력으로** 만들 것. 모든 VSCode/texlab 셋업의 forward/inverse 검색이 올바른 `.synctex.gz` 에 의존 — 없으면 통합이 네이티브하게 안 느껴짐.
- 공유 CLI = **엔진 바이너리 하나로 네이티브 iTex 앱과 VSCode 둘 다 백킹** → extension 작성보다 훨씬 쌈.

> 검증 메모: LaTeX Workshop 의 내부 viewer 는 PDF.js(WebView) + 로컬 HTTP/WebSocket 서버 기반이고, PDF 출력 파일을 debounce file-watcher(`latex-workshop.latex.watch.pdf.delay`, 기본 250ms)로 감지해 리프레시한다. 같은 WebSocket 채널이 SyncTeX forward/inverse 를 나른다. → iTex CLI 가 PDF + `.synctex.gz` 만 제대로 떨궈주면 끝. ([부록 LaTeX Workshop 항목](appendix-sources-and-verdicts.md))
