# 05. 검증 계획 & 단계별 구현 계획 & 리스크

> 각 레버를 독립적으로 증명하는 벤치마크 → 낮은노력·높은효과 순 단계별 계획 → 리스크/오픈질문.

---

## A. 검증 계획 (Validation)

> 절대 단일 집계 수치로 보고하지 말 것. 각 레버를 on/off A/B 로 증명한다.

### 코퍼스 (고정·버전관리)
1. **Text-heavy**: 30페이지 article, amsmath, 그래픽 없음 (본문 재타입셋 격리 — `.fmt`/warm 이 *가장 덜* 돕는 곳).
2. **Preamble-heavy**: TikZ/pgfplots/biblatex preamble (`.fmt`/warm 이 가장 효과 — C2 벤치마크 프로파일).
3. **Large-raster**: 20MP PNG(palette+alpha) 1개 + 20MP JPEG 1개 `\includegraphics` (C3 격리; PNG-vs-JPEG 비대칭 노출).
4. **TikZ-figure-heavy**: 비자명 `tikzpicture` 15개 (externalization 효과 격리).
5. **Cross-ref/biblio**: `\ref`/`\cite` 다수 + biber (C4 정확성 검증, 속도 아님).

### 지표 (Metrics)
- **First (cold) compile** — wall-clock, 캐시 빈 상태.
- **Warm compile** — wall-clock, 캐시 채워짐, 본문 1글자 편집.
- **Edit-to-preview latency** — 키스트로크 → PDFKit 갱신 표시 (사용자 체감 수치).
- **Correctness** — cross-ref/citation 번호/ToC 올바른가? (프로파일별 binary).
- **이미지 재임베드 비용** — 코퍼스 #3 의 draft vs normal 차이 (C3 를 문서별로 *확정*하는 진단).
- **PDFKit 리로드 jank** — 스크롤/줌 보존? swap 시 드롭 프레임.
- **SyncTeX 오버헤드** — `-synctex=0` vs `=1` vs `=-1`(비압축) 컴파일 시간 → 측정 안 된 gzip 비용 정량화.

### 방법 (Method)
- 각 기법 on/off A/B: `{baseline cold-spawn} vs {latexmk} vs {latexmk+draft} vs {warm-engine} vs {warm-engine+externalized} vs {Tectonic}`.
- `hyperfine` 식 반복 실행; median ± stddev 보고([Zorman 벤치마크](https://tony-zorman.com/posts/speeding-up-latex.html) 방법론 미러 → 27.66s→7.42s 와 비교 가능하게).
- Tectonic cold-vs-warm 디바이스별 타이밍: M-series + A-series (오픈질문 — iOS 공개 수치 없음).
- **게이트**: 어떤 기법이든 코퍼스 #5 의 정확성을 회귀시키지 않으면서 자기 타깃 지표를 개선할 때만 출하.

---

## B. 단계별 구현 계획 (Phased Plan)

> 낮은노력·높은효과 → 야심 순. Quick win 은 *기존* `LaTeXCompiler.swift` 안에서 먼저.

### Phase 0 — 기존 파일 안 quick win (수시간, macOS)
- **0a. raw 엔진 spawn → `latexmk`.** `LaTeXCompiler.swift:83-88` 의 `arguments` 를 `latexmk -synctex=1 -interaction=nonstopmode -file-line-error -pdf <file>` 로 교체. **C4(올바른 rerun+biber) + C5(SyncTeX 출력)** 를 ~10줄로. lib: `latexmk`(MacTeX 동봉). *노력: S.*
- **0b. Fast-Preview draft 토글.** preview 프로파일에 `\PassOptionsToPackage{draft}{graphicx}`(또는 `\documentclass[draft]`) 주입. **C3** raster 문서. lib: `graphicx`. *노력: S.*
- **0c. PDFKit viewport 보존.** `PDFPreviewView.swift:40-42`/`:57-59` 를 `scaleFactor` + `PDFDestination` 캡처/복원으로 재작성. **C7.** *노력: S.*
- **0d. Idle 기반 debounce.** 800ms debounce(`:32`) 유지하되 매 키스트로크 reset(이미 그럼) — 컴파일 빨라지면 500ms 로 낮춰도. *노력: XS.*

### Phase 1 — SyncTeX + figure 캐시 (수일, macOS)
- **1a. `synctex_parser.c` 벤더링** — 두 타깃 + bridging header; forward/inverse 를 에디터+PDFKit 에 배선(§4.3), Y-flip + `synctex_node_visible_h/v`. lib: [synctex-parser](https://ctan.org/pkg/synctex-parser). *노력: M.*
- **1b. Figure 캐시 + 이미지 프록시.** content-hash `\includegraphics`/TikZ → 캐시 PDF; 과대 raster 를 preview 용 ~300 DPI 로 사전 스케일. lib: TikZ `external`/`standalone` + ImageIO/`pngquant`. **C3 항구적 해결.** *노력: M.*

### Phase 2 — Warm engine (수일~수주, macOS) — "incremental" 산출물
- **2a. `WarmEngineBackend`** — tex-fast-recompile(또는 pre-warm-preamble 네이티브 재구현) 구동. **xelatex 용 C1+C2** 를 `.fmt` pdflatex 한계 없이. label/citation 변경 시 full latexmk fallback. lib: [tex-fast-recompile](https://github.com/user202729/tex-fast-recompile). 여기서 `CompileBackend` protocol(§4.1) 도입. *노력: M–L.*
- (선택 2b: pdflatex preview 경로가 허용되면 pdflatex `.fmt`/mylatexformat preview 프로파일.)

### Phase 3 — Tectonic in-process 코어 (수주, macOS + iOS) — 전략적
- **3a. `tectonic` crate 빌드** — `aarch64-apple-darwin`/`x86_64` + `aarch64-apple-ios`(+sim); harfbuzz/graphite2/freetype/ICU 크로스빌드; cbindgen + 얇은 C shim → XCFramework. 청사진: [Typetex](https://github.com/jonasgunklach/Typetex). *노력: L.*
- **3b. `TectonicBackend`** + 동봉 로컬 bundle + `format_cache_path`; **iOS 컴파일(C6) 해금** + macOS warm in-process 옵션(C1). 상대 graphics 경로 재검증. *노력: L.*
- **3c. iOS fallback 스파이크:** Tectonic-FFI iOS 가 너무 무거우면 *iff* WKWebView SwiftLaTeX-WASM — AGPL 클리어 게이트. *노력: M, 우발적.*

### Phase 4 — VSCode 브리지 (수일, Phase 0/1 이후 병렬 가능)
- **4a. `itex` CLI** — latexmk/tectonic 플래그 미러, PDF + `.synctex.gz` emit; LaTeX Workshop recipe + texlab `build.executable` + `.latexmkrc` 스니펫 배포. *노력: M.*
- **4b. (야심) LSP/빌드서버** — warm/Tectonic 파이프라인 래핑, 크로스에디터. *노력: L.*

**시퀀싱 근거**: Phase 0 가 macOS 사용자의 *보고된* 두 통증 + 잠재 정확성 버그 2개(C4·C7)를 수시간에 해결. Phase 1–2 가 정직한 "incremental" 이야기 산출. Phase 3 가 iOS 해금 + 영속 warm 엔진의 무거운 전략 베팅. Phase 4 가 fork 없이 설정만으로 사용자의 VSCode 워크플로 도달.

### 노력 vs 효과 한눈에
| Phase | 노력 | 고치는 것 | 산출 가치 |
|---|---|---|---|
| **0** | S×3 | C4·C5·C7 + C3 일부 | **즉시 / 두 통증 1차 + 숨은 버그** |
| 1 | M×2 | C5 배선·C3 항구 | forward/inverse + figure 상수비용 |
| 2 | M–L | C1·C2 | warm "incremental" 체감 |
| 3 | L×2 | C6·C1 | **iOS 해금** + 영속 warm |
| 4 | M(+L) | 확장성 | VSCode/크로스에디터 도달 |

---

## C. 리스크 & 오픈 질문

### 라이선스
- **texlab = GPL-3.0** — fork 시 GPL 의무. clean-room LSP 또는 CLI 통합 선호. ([texlab](https://github.com/latex-lsp/texlab))
- **SwiftLaTeX = AGPL-3.0** — 네트워크 조항 copyleft, 폐쇄형 App Store 앱에 높은 리스크. iOS 경로로 의존하기 전 클리어 필수. ([repo](https://github.com/SwiftLaTeX/SwiftLaTeX))
- **호환 OK**: Tectonic(MIT), latexmk(GPL, subprocess — 링크 의무 없음), mylatexformat/standalone(LPPL), synctex_parser(permissive), tex-fast-recompile(MIT), Typst/comemo(Apache-2.0).

### iOS / Tectonic-FFI
- **공개된 프로덕션 `aarch64-apple-ios` Tectonic 빌드 부재.** Typetex 는 macOS 만 활성. iOS in-process 빌드는 *그럴듯*(순수 Rust + C, fork 없음)하나 **미검증** — App Store entitlement 하에 링크·실행되는지 스파이크 필요.
- **바이너리 ~200MB**(Typetex `libtectonic_ffi.a`) + 동봉 TeXLive 부분집합 — iTex App Store 용량 예산 허용? 오픈.
- **Tectonic 런타임 CTAN fetch 가 iOS 샌드박스에서 되나?** prebundled 로컬 bundle 또는 네트워크+쓰기캐시 필요 — hermetic 로컬 bundle 경로를 만들고 최소화해야.
- **A-/M-series cold-vs-warm Tectonic 지연** 미측정. format-cache 가 전형 문서의 run 당 지연을 의미있게 줄이는지 로컬 타이밍 필요.

### 엔진/기법 주의 (carry-forward)
- **`.fmt` 프리컴파일은 pdflatex 전용** — iTex xelatex 기본과 충돌. pdflatex preview 엔진 분리를 받아들이거나, xelatex fidelity 위해 tex-fast-recompile warm 경로로. (오픈: 편집 중에도 xelatex/OTF fidelity 보존 필수인가?)
- **Warm engine cross-ref 정확성**: tex-fast-recompile 이 reference 변경 시 under-rerun 가능, preamble-영역 SyncTeX 가 약간 어긋날 수 있음 — *본문*(사용자 편집 지점) 클릭-sync 정밀도 검증, 항상 full latexmk pass 로 마무리.
- **`-shell-escape` 요구** — TikZ externalization + 쓰기 가능 캐시. iTex 샌드박스(특히 iOS) 허용 확인.
- **상대 `\includegraphics`/`\input` 경로 해석** — Tectonic 의 관리 작업 디렉터리가 iTex 현재 compile-in-source-dir(`LaTeXCompiler.swift:55-63`)과 다름 — 재검증.
- **Python 런타임 의존**(tex-fast-recompile): 번들하거나 pre-warm 트릭을 Swift/Rust 로 재구현해 의존 제거.

### 제품/범위 질문
- **iTex 타깃 문서 중 graphics/preamble-heavy 비율**(warm+externalize 효과) vs text-heavy(본문 재타입셋 지배, 효과 적음)? → Phase 2/3 ROI 좌우.
- **byte-accurate 미리보기가 필요한가, 편집 루프에선 근사 fast preview 로 충분한가?** 후자면 옵션 넓어짐(편집 중인 수식/figure 만 `preview.sty` + `dvipng` 로 snippet 렌더, counter 는 근사 허용 — [preview-latex](https://www.gnu.org/software/auctex/manual/preview-latex.html)).
- **latexmk 의 `.fls`/`.fdb` 로직을 네이티브 재구현할 가치가 있나** vs latexmk shell-out(macOS) — 그리고 latexmk subprocess 없는 iOS 계획(Tectonic 은 내부 multi-pass 자체 처리).
- **Typst 2nd 엔진**: LaTeX→Typst 변환 fidelity 한계(pandoc/MiTeX/tylax)가 진짜 TikZ/커스텀매크로/biblatex 문서에서 충분한가, 아니면 엄격히 병렬 트랙인가.

---

## 정직한 결론 (Bottom line)

진짜 region 단위 incremental LaTeX 은 불가능하다. iTex 의 방어 가능한, OSS 로 뒷받침되는 이야기는 **warm-engine + cached-figures + draft preview + skip-unneeded-reruns** 이며, **Tectonic** 이 유일하게 **iOS** 를 해금하는 in-process 코어, **SyncTeX** 가 네이티브 에디터와 VSCode 브리지 둘 다를 네이티브하게 만드는 table-stakes 다. 가장 빠른 실제 승리(latexmk 교체 + draft 모드 + viewport 보존 PDFKit 리로드)는 *오늘* 기존 `LaTeXCompiler.swift`/`PDFPreviewView.swift` 안에서 적은 코드로 가능하다.
