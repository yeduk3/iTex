# 03. 해결방안 — 기법 메뉴

> 각 기법: 무엇을 고치는지 / 효과(payoff) / 비용 / **그걸 제공하는 OSS 라이브러리**(→ iTex 는 glue 만 쓰고 엔진 코드는 안 씀).
> 매핑은 [02-concretization.md](02-concretization.md) 의 C1~C7 을 가리킨다.

---

## 3.1 latexmk 의존성 추적 + `-pvc` — C4 해결, C1 일부
- **무엇**: Perl 오케스트레이터. 엔진을 올바른 횟수만큼 실행(`.fls`/`.log`/`.aux` 파싱, 상태를 `.fdb_latexmk` 에 저장), biber/bibtex 자동 실행, cross-ref 안정될 때까지 rerun, SyncTeX 출력. **incremental 컴파일러 아님** — *불필요한 전체 rerun* 을 생략할 뿐. ([latexmk man](https://manpages.debian.org/testing/latexmk/latexmk.1.en.html))
- **효과**: ~10줄 변경으로 올바른 cross-ref/bib + SyncTeX. `.aux`/`.bbl`/`.fls` 를 컴파일 간 재사용.
- **비용**: Perl subprocess (macOS 전용; MacTeX 동봉). iOS 엔 도움 안 됨.
- **라이브러리**: `latexmk` ([CTAN](https://ctan.org/pkg/latexmk)). **macOS 최저비용 승리.**

## 3.2 Precompiled `.fmt` / mylatexformat (warm format) — C2 해결
- **무엇**: preamble 의 인메모리 매크로/폰트/하이프네이션 상태를 `.fmt` 로 덤프 → 매 run 즉시 리로드. ([mylatexformat](https://ctan.org/pkg/mylatexformat))
- **효과**: 무거운 preamble 에서 run 당 ~73% 절감(C2 벤치마크).
- **비용 / 날카로운 주의**: **pdflatex 에서만 잘 됨, xelatex/lualatex 는 안 됨** — fontspec/luaotfload 상태를 덤프 못 함("각 엔진마다 다른 문제", [latexmk precompile-preamble rcfile](https://tug.ctan.org/support/latexmk/example_rcfiles/precompile-preamble_latexmkrc)). iTex 기본이 **xelatex** 이므로 이 경로는 pdflatex "preview 엔진" 분리를 강요하거나 **§3.3 으로 대체**.
- **라이브러리**: `mylatexformat` (latexmk `$make_fmt` 경유).

## 3.3 Warm pre-started engine (tex-fast-recompile) — *xelatex 용* C1+C2 — 현실적 "incremental"
- **무엇**: 편집 idle 시간에 새 엔진을 시작해 **변하지 않는 preamble** 을 처리한 뒤 본문을 기다리며 블록. 저장 시 바뀐 본문을 먹여 본문만 실시간 타입셋. ([PyPI](https://pypi.org/project/tex-fast-recompile/), [README](https://github.com/user202729/tex-fast-recompile))
- **효과**: "바뀐 부분만 재컴파일" 에 가장 가까운 지연. 결정적으로 **xelatex/lualatex(OpenType 폰트·Lua 포함)에서 동작** — 바로 `.fmt` 가 실패하는 지점. mylatexformat 와 병용 가능.
- **비용 / 정확성 주의**: Python 런타임 의존(번들하거나, pre-warm 트릭을 Swift/Rust 로 재구현). latexmk 에뮬레이션이 "reference 변경 시 충분히 rerun 안 할 수 있음" → label/citation 정착엔 **여전히 full latexmk pass 필요**. ([README](https://raw.githubusercontent.com/user202729/tex-fast-recompile/main/README.md))
- **라이브러리**: `tex-fast-recompile` (MIT). Python 을 번들 안 하더라도 **기법 자체가 가치**.

> 📌 구현 디테일 주의: tex-fast-recompile 의 정확한 메커니즘(매 idle 마다 fresh 시작 후 재사용 vs preamble 체크포인트 fork)은 리서치에서 표현이 갈렸다. **확실한 것은 결과**: preamble 작업 재사용, xelatex 호환, MIT, cross-ref under-rerun 가능. 의존하기 전 README 로 fork/no-fork 디테일 확인.

## 3.4 Draft mode — C3 를 싸게 해결
- **무엇**: `\documentclass[draft]` 또는 `\usepackage[draft]{graphicx}` 가 **이미지 디코드+임베드를 억제**하고, 파일명이 적힌 올바른 크기의 placeholder 박스를 emit. ([graphicx manual](https://texdoc.org/serve/graphicx.pdf/0); [Overleaf "Fast" mode](https://docs.overleaf.com/getting-started/recompiling-your-project))
- **효과**: raster-heavy 문서 편집 중 단일 최대 승리. pagination + SyncTeX 유효 유지.
- **비용 / 주의**: draft 도 **bounding-box 메타데이터는 읽는다**(명시적 `width`/`height` 또는 `.xbb` sidecar 없으면). 이미지 *데이터*만 스킵, 크기 헤더는 아님. → 데이터 스킵이지 zero-I/O 아님.
- **라이브러리**: `graphics`/`graphicx` 내장. 한 줄 토글.

## 3.5 TikZ externalization / standalone figure 캐시 — C3 해결 (유일한 진짜 본문 캐시)
- **무엇**: 각 `tikzpicture`/figure 를 MD5 키로 한 번만 PDF 로 컴파일(`\usetikzlibrary{external}`, `standalone` 클래스). 바뀐 figure 만 재빌드, 나머지는 캐시 PDF 재사용. ([tikz external](https://tikz.dev/library-external), [standalone](https://ctan.org/pkg/standalone))
- **효과**: 무거운 figure 를 이후 매 컴파일에서 **상수 비용**으로. warm engine 과 복합 효과.
- **비용**: `-shell-escape` + 쓰기 가능 캐시 디렉터리 필요. 첫 빌드는 여전히 느림. TikZ 느림은 *계산적*(PGF 경로 수학)이라 raster 임베드와 다른 클래스 — externalization 은 출력을 캐싱해 두 부류 다 처리.
- **라이브러리**: PGF/TikZ `external`, `standalone`. iTex 는 평범한 `\includegraphics` 프록시용으로 *content-hash → cached PDF* 를 자체 구현해도 됨.

## 3.6 이미지 프록시/사전 스케일 캐시 — non-TikZ raster 용 C3
- **무엇**: 엔진이 리샘플을 안 하므로, 과대 `\includegraphics` 타깃을 표시 크기 기준 ~300 DPI 로 사전 다운스케일. 미리보기 땐 프록시 대체, export 때만 풀해상도.
- **효과**: photo-heavy 문서에서 draft placeholder 없이 지배적 임베드 비용 제거.
- **비용**: 적당한 자체 코드. 소스+타깃 크기로 키잉한 content-hash 캐시 필요.
- **라이브러리**: `pngquant` / ImageIO / `sips` 로 다운스케일. ([Overleaf images](https://www.overleaf.com/learn/latex/Inserting_Images))

## 3.7 Tectonic in-process 라이브러리 — C1 + C6 (전략적 코어)
- **무엇**: 자족적 XeTeX + xdvipdfmx 엔진을 **Rust crate** 로. V1 `latex_to_pdf() -> Result<Vec<u8>>`, V2 `driver::ProcessingSessionBuilder`(커스텀 bundle, `format_cache_path`, `OutputFormat`). 정적 링크, **subprocess 없음**. ([docs.rs/tectonic](https://docs.rs/tectonic/latest/tectonic/), [repo](https://github.com/tectonic-typesetting/tectonic))
- **효과**: subprocess cold-start(C1)를 in-process/warm 실행으로 제거. **iOS 컴파일(C6)의 유일한 현실적 길**(순수 Rust + vendored C, fork 없음). `--synctex` 지원. 선례: **Typetex** 가 `libtectonic_ffi.a`(~200MB)를 C-FFI 정적 lib 로 Swift macOS/iPadOS 에디터에 동봉(거기선 macOS 전용으로만 Tectonic 활성). ([Typetex](https://github.com/jonasgunklach/Typetex))
- **비용 / 정직한 주의**:
  - **기본값은 hermetic 아님.** TeXLive 지원파일 *bundle* + 생성된 format 파일이 필요하고, **첫 실행에 네트워크로 다운로드**해 `TECTONIC_CACHE_DIR` 에 캐시. iOS 는 **로컬 bundle 을 동봉**하고 가리켜야 함(네트워크 의존 X). ([Tectonic book — bundles](https://tectonic-typesetting.github.io/book/latest/v2cli/bundle.html), [first-document](https://tectonic-typesetting.github.io/book/latest/getting-started/first-document.html))
  - **Rust API 뿐.** Swift 에서 임베드하려면 정적 lib 크로스컴파일(`aarch64-apple-ios` + sim) + 얇은 C-FFI shim(cbindgen). 무거운 C 의존(harfbuzz, graphite2, freetype, ICU) 크로스컴파일 필요. ~200MB 바이너리 + App Store 용량 심사.
  - **캐싱은 assets+format 만**, 문서 레벨 incremental 아님 — 매 run 전체 재타입셋(한 invocation 안에서 `.aux` 변하면 multi-pass). 즉시 미리보기엔 iTex 가 위에 warm/diffing 로직을 얹어야 함.
- **라이브러리**: `tectonic` crate (MIT); FFI 는 `cbindgen` + 얇은 C shim → XCFramework. 패키징 청사진은 Typetex.

## 3.8 Typst — 학습용 incremental 황금기준 / 선택적 2nd 엔진
- **무엇**: Rust 타입세팅 시스템. incrementality 가 **comemo** constrained memoization 위에 구축 — parse→eval→layout→export 중 영향받은 가지만 재실행 → sub-second live preview. 라이브러리로 사용 가능(`typst` crate; web/WASM 은 `typst.ts`/`reflexo`). ([comemo](https://github.com/typst/comemo), [architecture](https://github.com/typst/typst/blob/main/docs/dev/architecture.md))
- **효과**: 진짜 incremental recompute 를 가진 *유일한* mainstream 시스템 — 연구할 아키텍처(그리고 `comemo` 는 iTex 가 자체 파이프라인을 만든다면 재사용 가능한 primitive).
- **비용 / 주의**: **LaTeX 가 아님.** 공존하려면 변환(pandoc, MiTeX, tylax) 필요, TikZ/커스텀 매크로/biblatex 문서엔 실제 fidelity 한계. incrementality 는 **인메모리 watch 모드 한정**, CLI run 간 영속 아님. ([typst issue #8203](https://github.com/typst/typst/issues/8203))
- **권고**: LaTeX 호환 경로가 아닌 **병렬 전략 트랙**으로 유지.

## 3.9 SwiftLaTeX-WASM — Tectonic-FFI 가 너무 무거울 때 iOS 대체
- **무엇**: 진짜 XeTeX/PdfTeX 를 WebAssembly 로 컴파일. 인메모리 FS, on-demand CTAN fetch, ~2× 네이티브 속도, TeXLive 동일 출력. WKWebView 에서 실행. ([swiftlatex.com](https://www.swiftlatex.com/), [repo](https://github.com/SwiftLaTeX/SwiftLaTeX))
- **비용 / 차단요인**: **AGPL-3.0** — 강한 copyleft/네트워크 조항, 폐쇄형 App Store 앱엔 실질 리스크. 라이선스 클리어 필수. 비교적 휴면 상태. 네이티브 앱과 VSCode webview 간 재사용은 가능.
- **라이브러리**: SwiftLaTeX WASM 엔진. 주력이 아닌 보험 옵션.

## 3.10 SyncTeX — C5 해결 (forward/inverse 검색)
- **무엇**: 엔진에 `-synctex=1`(*비트필드*; 양수 → gzip `.synctex.gz`, 음수 → plain `.synctex`) 전달. Jerome Laurens 의 휴대용 **C `synctex_parser`** 임베드(또는 `synctex` CLI 호출)로 forward(line→page+rect)·inverse(page+click→file+line) 쿼리. ([synctex(1)](https://man.archlinux.org/man/synctex.1.en), [CTAN synctex-parser](https://ctan.org/pkg/synctex-parser))
- **구현 핵심 사실(정정됨)**:
  - **`.synctex.gz` 를 직접 파싱하지 말 것.** 포맷은 비공개 선언됨 — parser 라이브러리를 호출. 노드 좌표는 *small points × Unit* 로 저장(raw scaled points 아님). `synctex_node_visible_h/v` 는 magnification/offset 적용된 **72-dpi(PDF big-point)** float 를 이미 반환. 단순 `/65536` 은 **틀림**. ([synctex_parser.h](https://github.com/jlaurens/synctex/blob/main/synctex_parser.h))
  - **PDFKit Y축 뒤집기**: SyncTeX 는 좌상단 원점(y-down), PDFKit 은 좌하단(y-up). 양방향 flip.
  - `f`(form) 레코드는 *form tag* 를 담음 — input-file id + line 이 **아님**. 모든 레코드를 line-tagged 로 취급 금지.
- **라이브러리**: `synctex_parser.c` 를 macOS *와* iOS 타깃에 직접 벤더링(순수 C, subprocess 없음). `.synctex.gz` 는 Tectonic `--synctex` 또는 latexmk `-synctex=1` 가 생성.

---

## 기법 → 하위문제 → 효과/비용 요약

| 기법 | 고침 | 효과 | 비용 | OSS | 단계 |
|---|---|---|---|---|---|
| latexmk | C4(+C5출력) | 정확한 rerun·bib·SyncTeX | macOS only | latexmk | **P0** |
| `.fmt`/mylatexformat | C2 | ~73%↓ preamble | **pdflatex 전용** | mylatexformat | P2(선택) |
| warm engine | C1+C2 | "incremental" 최근접 | Python 의존·under-rerun | tex-fast-recompile | P2 |
| draft mode | C3 | raster 편집 최대 승리 | bbox 는 읽음 | graphicx | **P0** |
| externalize | C3 | figure 상수비용 | shell-escape·첫빌드 느림 | TikZ external/standalone | P1 |
| 이미지 프록시 | C3 | photo 임베드 제거 | 자체 캐시 코드 | sips/ImageIO/pngquant | P1 |
| Tectonic | C1+C6 | iOS 가능·in-proc warm | ~200MB·FFI·bundle | tectonic crate | P3 |
| Typst | (참고) | 진짜 incremental 학습 | LaTeX 아님 | typst/comemo | 병렬 |
| SwiftLaTeX-WASM | C6(대체) | iOS WASM | **AGPL** | SwiftLaTeX | P3(우발) |
| SyncTeX | C5 | forward/inverse | Y-flip·parser 필수 | synctex_parser.c | P0/P1 |
