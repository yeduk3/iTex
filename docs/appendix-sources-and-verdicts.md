# 부록 — 출처 & 적대적 검증 정정

> 조사 방법: 6갈래 출처기반 리서치(축마다 독립 에이전트) → 핵심 주장 18건을 **적대적 검증**(각 주장을 *반박*하려 시도) → 종합.
> 검증 결과: **확정(confirmed) 6 / 부분확정(partial) 12 / 반박(refuted) 0**. partial = 주장의 핵심은 살아남았으나 정밀화/단서가 붙음.
> 아래는 *설계에 영향을 준* 정정만 추렸다. 전체 raw 출력: 워크플로 transcript 참조.

---

## 1. 설계 결정에 영향을 준 핵심 정정 (corrections)

### TeX 실행 모델 (PARTIAL)
- "단일 forward pass" 는 단순화. 한 run 안에서 expansion↔execution 은 **교차**되고, `\unskip`/`\lastbox`/page builder 는 되돌림/피드백을 만든다. **결정적 이유는 엔진이 아니라 문서 레벨** — cross-ref/ToC/citation 이 `.aux`/`.toc` 를 거쳐 *다음 run* 에 반영. bib(`.bbl`)은 LaTeX pass 가 아니라 외부 BibTeX/Biber 산출물. (인용했던 Wikipedia 는 이 메커니즘을 실제로 기술하지 않음; arXiv:2603.02873 은 중립 서베이가 아니라 Mogan STEM 광고성 — **약한 출처로 강등**.)
- Turing-completeness: expansion-only 레벨에서도 참(Alan Jeffrey, TUGboat 11:2, 1990, 람다 계산). 단 "실제로 돌려봐야 하는" 지배적 실무 이유는 Turing-completeness 가 아니라 **전역 가변 상태**.

### 이미지 병목 (PARTIAL — 사용자 문제 1 직접 관련)
- "PNG 는 무조건 느리다" 는 **시대착오**. pdfTeX ~1.40(2007, `copy_png`, 현 TeX Live `writepng.c`) 이후 non-interlaced·alpha 없음·tRNS 없음·gamma==1·PDF≥1.2 PNG 는 JPEG 처럼 스트림 그대로 복사. 풀 재인코드는 **palette/indexed·alpha(SMask)·tRNS·interlaced·gamma≠1** 에서만.
- "graphicx 가 이미지를 PDF 에 맞춘다" 는 부정확 — graphicx 는 driver-독립 프런트엔드, 실제 임베드는 엔진/드라이버(pdftex.def `\pdfximage`, XeTeX 는 xdvipdfmx). latex+dvips 경로는 `.tex` 단계에서 아무것도 임베드 안 함(`\special` 만).
- draft 모드는 이미지 *데이터* 디코드/임베드만 스킵, **bounding-box 헤더는 여전히 읽음**(명시 크기 없으면). zero-I/O 아님.
- "느린 컴파일 #1 원인 = 과대 이미지" 는 **과장** — 인용 출처들끼리 1순위가 갈림(이미지 vs TikZ vs monolithic .tex). draft-vs-normal 진단은 유용하나 불완전(전역 `[draft]` 부작용, TikZ 그림은 draft 로 안 잡힘). → **문서별 확인 필수.**

### incremental / warm engine (PARTIAL)
- 진짜 per-region incremental 은 mainstream TeX(Tectonic 포함, XeTeX wrap)에 **없음** 확정. 대체재 4종(`.fmt`, warm engine, latexmk, externalize)은 모두 실재.
- **`.fmt` 프리컴파일은 latex/pdflatex 사실상 전용** — XeTeX/LuaTeX 는 fontspec/luaotfload·Lua 상태를 format 에 못 덤프(latexmk rcfile 명시: "xelatex and lualatex don't work with precompiled preambles", 2023-12-22 테스트). 정정: 이 사실이 "pdflatex 로 갈아타라" 를 강요하진 않음 — **tex-fast-recompile(fork-after-preamble, no .fmt)이 xelatex/OTF/Lua 에서 동작**하므로 그 길로.
- warm engine 정확성 단서: tex-fast-recompile latexmk 에뮬레이션이 reference 변경 시 **under-rerun 가능** → label/citation 정착엔 full latexmk pass 필요.

### Tectonic (CONFIRMED + 1 PARTIAL)
- V1 `latex_to_pdf() -> Result<Vec<u8>>`, V2 `driver::ProcessingSessionBuilder`(+`OutputFormat`, `bundle()`, `format_cache_path()`) **확정**(docs.rs 대조). C/C++ 엔진 ↔ Rust 는 cbindgen 헤더(`tectonic_bridge_core` C API, `tectonic_engine_xetex`) **확정**.
- PARTIAL 정정: **기본값은 hermetic 아님** — TeXLive bundle + format 파일이 필요하고 첫 실행에 네트워크 다운로드 후 `TECTONIC_CACHE_DIR` 캐시. 공식 문구 "without externally installed software" 는 "사용자가 TeX 배포판을 사전설치 안 해도 됨" 이지 "지원파일 불필요" 가 아님. **iOS 는 로컬 bundle 동봉 필수.** 캐싱은 assets+format 만, 문서 incremental 아님.

### LaTeX Workshop (CONFIRMED — 2026-06-26 GitHub API 대조)
- MIT, 12,176 스타("12.2k"), master 정확히 6,597 커밋, TypeScript 우세(JS/CSS/HTML 도 상당), 활발(last push 2026-06-22).
- recipe = `{name, tools}`(tools 는 tool *이름* 배열), tool = `{name, command, args?, env?, cwd?}`(다른 필드 불가). 기본 latexmk args = `["-synctex=1","-interaction=nonstopmode","-file-line-error","-pdf","-outdir=%OUTDIR%","%DOC%"]`. placeholder: `%DOC%`,`%OUTDIR%`,`%DIR%`,… default recipe `"first"`.
- 내부 viewer = PDF.js(WebView) + 로컬 HTTP/WebSocket. PDF 출력 파일을 debounce file-watcher(기본 250ms)로 감지해 리프레시. 같은 WS 채널이 SyncTeX forward/inverse 나름. → **iTex CLI 가 PDF + `.synctex.gz` 만 제대로 떨구면 통합 끝.**

### SyncTeX (CONFIRMED + 2 PARTIAL — 구현 함정)
- `-synctex=N` 은 **비트필드**: 부호가 압축 선택(양수 → `.synctex.gz`, 음수 → plain). bit 추가로 동작 튜닝(`-synctex=15` = 전부). pdftex/xetex/luatex 동일 스위치. **확정.**
- **직접 파싱 금지** — 포맷 비공개 선언. 좌표는 "TeX small points × Unit"(기본 Unit=1sp)이라 단순 `/65536` **틀림**. `synctex_node_visible_h/v` 가 magnification/offset/72.27-vs-72 적용된 **72-dpi float** 반환 → 그걸 쓸 것. Post Scriptum 은 preamble 변환을 **덮어씀(override)**.
- `f`(form) 레코드는 *form tag*, input-file+line **아님** — 모든 레코드를 line-tagged 로 취급 금지.

---

## 2. 출처 모음 (119건, 주제별)

### TeX 실행 모델 / incremental 원리
- TeX by Topic (Eijkhout) https://texdoc.org/serve/texbytopic/0
- Wikipedia TeX https://en.wikipedia.org/wiki/TeX
- Overleaf "How TeX macros actually work" https://www.overleaf.com/learn/latex/How_TeX_macros_actually_work%3A_Part_6
- LaTeX2e cross-references https://latexref.xyz/Cross-references.html
- KaTeX #139 (왜 비실행 렌더러로 임의 TeX 불가) https://github.com/KaTeX/KaTeX/issues/139
- Overleaf INI vs production mode https://www.overleaf.com/learn/latex/Articles/The_two_modes_of_TeX_engines:_INI_mode_and_production_mode

### 이미지 병목 / draft / 임베드
- graphicx manual https://texdoc.org/serve/graphicx.pdf/0
- texlive-source writepng.c (copy_png) https://github.com/TeX-Live/texlive-source/blob/trunk/texk/web2c/pdftexdir/writepng.c
- Hoekwater, comp.text.tex (JPEG/PNG 임베드) https://groups.google.com/g/comp.text.tex/c/LGZIaX5tbYU
- dvipdfmx docs https://tug.org/dvipdfmx/doc/dvipdfmx/dvipdfmx.pdf
- epstopdf https://wiki.math.uzh.ch/public/LaTeX/epstopdf
- Overleaf Inserting Images https://www.overleaf.com/learn/latex/Inserting_Images
- 느린 컴파일 진단(상충 출처): https://www.thetapad.com/blog/speed-up-latex-compilation · https://tony-zorman.com/posts/speeding-up-latex.html · https://trybibby.com/blog/fix-slow-latex-compilation

### 프리컴파일 / latexmk / warm engine
- mylatexformat https://ctan.org/pkg/mylatexformat · https://ctan.math.utah.edu/ctan/tex-archive/macros/latex/contrib/mylatexformat/README
- latexmk man https://manpages.debian.org/testing/latexmk/latexmk.1.en.html · https://ctan.org/pkg/latexmk
- latexmk precompile-preamble rcfile (xelatex 불가 명시) https://tug.ctan.org/support/latexmk/example_rcfiles/precompile-preamble_latexmkrc
- tex-fast-recompile https://github.com/user202729/tex-fast-recompile · https://pypi.org/project/tex-fast-recompile/
- latex-fast-compile(Go) https://pkg.go.dev/github.com/kpym/latex-fast-compile
- Zorman 벤치마크(27.66s→7.42s) https://tony-zorman.com/posts/speeding-up-latex.html
- Sak 빌드시스템 비교 https://blog.martisak.se/2023/10/01/compiling/
- lukidean preamble compilation https://lukideangeometry.xyz/blog/preamble-compilation

### figure 캐시 / externalization
- TikZ external https://tikz.dev/library-external · pgf https://ctan.org/pkg/pgf
- standalone https://ctan.org/pkg/standalone
- preview / preview-latex https://ctan.org/pkg/preview · https://www.gnu.org/software/auctex/manual/preview-latex.html

### 임베드 엔진 (Tectonic / Typst / SwiftLaTeX / 기타)
- Tectonic repo https://github.com/tectonic-typesetting/tectonic · docs.rs https://docs.rs/tectonic/latest/tectonic/
- Tectonic bundles/first-doc https://tectonic-typesetting.github.io/book/latest/v2cli/bundle.html · https://tectonic-typesetting.github.io/book/latest/getting-started/first-document.html
- tectonic_bridge_core / engine_xetex https://lib.rs/crates/tectonic_bridge_core · https://crates.io/crates/tectonic_engine_xetex
- Typetex(Swift+Tectonic FFI 선례) https://github.com/jonasgunklach/Typetex
- Typst / comemo / architecture https://github.com/typst/typst · https://github.com/typst/comemo · https://github.com/typst/typst/blob/main/docs/dev/architecture.md
- Typst incremental(watch-only) https://github.com/typst/typst/issues/8203 · https://forum.typst.app/t/recompilation-where-does-typst-cli-store-recompilation-artefacts/4471
- LaTeX↔Typst 변환 https://typst.app/universe/package/mitex/ · https://github.com/scipenai/tylax · https://typst.app/docs/guides/for-latex-users/
- SwiftLaTeX(AGPL) https://github.com/SwiftLaTeX/SwiftLaTeX · https://www.swiftlatex.com/
- MiKTeX https://github.com/MiKTeX/miktex · TeXLive https://www.tug.org/texlive/
- KaTeX/MathJax(수식 전용) https://katex.org/ · https://www.mathjax.org/

### VSCode 생태계 / LSP
- LaTeX Workshop https://github.com/James-Yu/LaTeX-Workshop · Compile wiki https://github.com/James-Yu/LaTeX-Workshop/wiki/Compile · View wiki https://github.com/James-Yu/latex-workshop/wiki/View
- LaTeX Workshop 아키텍처 https://deepwiki.com/James-Yu/LaTeX-Workshop
- Tectonic recipe 선례 https://github.com/tectonic-typesetting/tectonic/discussions/1181
- texlab(GPL-3.0) https://github.com/latex-lsp/texlab · config https://github.com/latex-lsp/texlab/wiki/Configuration
- VSCode API https://code.visualstudio.com/api
- latexmk+biber VSCode 셋업 https://nelsonaloysio.medium.com/setting-up-vs-code-to-write-in-latex-using-latexmk-and-biber-plus-extras-b4b37c844495

### SyncTeX / 미리보기 / PDFKit
- synctex(1)/(5) https://man.archlinux.org/man/synctex.5.en
- synctex_parser.h (Laurens) https://github.com/jlaurens/synctex/blob/main/synctex_parser.h · CTAN https://ctan.org/pkg/synctex-parser
- Laurens TUGboat 29:3 https://tug.org/TUGboat/tb29-3/tb93laurens.pdf
- SyncTeX in LaTeX Workshop/Okular https://zhauniarovich.com/post/2023/2023-03-configuring-forward-and-inverse-search-in-latex-workshop-and-okular/
- Skim/Sioyek sync https://sourceforge.net/p/skim-app/wiki/TeX_and_PDF_Synchronization/ · https://github.com/ahrm/sioyek/discussions/347
- PDF.js lazy render https://github.com/mozilla/pdf.js/issues/7391 · repo https://github.com/mozilla/pdf.js
- PDFKit https://developer.apple.com/documentation/pdfkit
- Overleaf compile/timeout https://docs.overleaf.com/getting-started/recompiling-your-project · https://github.com/overleaf/overleaf/blob/main/services/clsi/README.md

### Rust↔Swift FFI / iOS
- iOS Process 제약 https://developer.apple.com/forums/thread/673387
- Rust on iOS https://mozilla.github.io/firefox-browser-architecture/experiments/2017-09-06-rust-on-ios.html
- Calling Rust from Swift https://www.strathweb.com/2023/07/calling-rust-code-from-swift/
- uniffi https://github.com/mozilla/uniffi-rs · https://boehs.org/node/uniffi
- Apple Silicon build https://developer.apple.com/documentation/technotes/tn3117-resolving-build-errors-for-apple-silicon
