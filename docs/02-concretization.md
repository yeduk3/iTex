# 02. 문제 구체화 — 측정 가능한 하위문제

> 두 문제를 독립적으로 측정 가능한 비용으로 분해한다. 리서치가 수치를 준 곳은 수치를 박았다.
> 각 항목은 [03-solution-space.md](03-solution-space.md) 의 기법, [05-validation-and-plan.md](05-validation-and-plan.md) 의 단계와 연결된다.

---

## 하위문제 표 (C1 ~ C7)

| # | 하위문제 | 현재 iTex 위치 | 크기 / 근거 |
|---|---|---|---|
| **C1** | **Cold-start subprocess spawn** | `LaTeXCompiler.swift:74-88` 가 매 컴파일마다 `/usr/bin/env xelatex …` 를 새로 fork | 매 컴파일마다 process fork + kpathsea 초기화 + format 로드. in-process 엔진(Tectonic)으로 완전 제거하거나, resident/warm 프로세스로 분할 상환. |
| **C2** | **Preamble 재파싱 / 패키지 로드** | 매 run 마다 preamble 전체 재확장 | 벤치마크 TikZ/pgfplots 문서: **27.66s(baseline) → 7.42s(.fmt 프리컴파일)** ≈ **73% 절감**. ([Zorman](https://tony-zorman.com/posts/speeding-up-latex.html)) 단 **`.fmt` 는 pdflatex 전용**(xelatex 불가, §3 참조). |
| **C3** | **매 run 이미지 재임베드** | 이미지 캐시 없음. 매 키스트로크 재임베드 | 포맷 의존(§01). JPEG/평범한 PNG/PDF ≈ 스트림 복사. palette/alpha PNG 와 과대 raster 가 지배적. draft/externalize 로 **상수 비용**화. |
| **C4** | **불필요/부족한 rerun + bib (정확성)** | iTex 는 엔진 **1회**(`-halt-on-error`) → cross-ref/citation/ToC 종종 **틀림**(rerun·biber 없음) | 속도가 아닌 **정확성 버그**. iTex 는 현재 수렴을 *under-run*. latexmk 가 `.aux` 안정까지 rerun 해 해결. |
| **C5** | **SyncTeX 없음** | `-synctex` 미전달 (`:85-88`) | forward(소스→PDF)/inverse(클릭→소스) 검색 불가. SyncTeX 오버헤드는 작음(geometry 로깅 + gzip), 지연의 주범 아님. ([Laurens TUGboat](https://tug.org/TUGboat/tb29-3/tb93laurens.pdf)) |
| **C6** | **iOS 불가능** | `buildPDF` 는 `#if os(macOS)`; 그 외 `throw .platformUnsupported`(`:109-111`) | iOS 샌드박스가 `Process`/fork-exec 차단. **in-process 엔진**(Tectonic 정적 lib, 또는 WKWebView 의 SwiftLaTeX-WASM)만 iOS 컴파일 가능. ([Apple forums](https://developer.apple.com/forums/thread/673387)) |
| **C7** | **PDFKit 콜드 전체 리로드 (정확성/UX)** | `PDFPreviewView.swift:40-42`/`:57-59` 가 매 `compilationID` 변경마다 `view.document = PDFDocument(url:)` | 매 재컴파일마다 스크롤·줌 폐기 + 문서 전체 재파싱. 해법: `scaleFactor` + `PDFDestination` 캡처/복원 → 보이는 페이지만 재래스터화. ([PDF.js lazy-render](https://github.com/mozilla/pdf.js/issues/7391)) |

---

## 읽는 법

- **속도 레버**: C1(cold start), C2(preamble), C3(이미지) — 이 셋이 edit-to-preview 지연의 대부분.
- **정확성 레버(숨은 버그)**: C4(잘못된 cross-ref/bib), C7(미리보기 리셋) — 속도 작업과 함께 고쳐야 함.
- **플랫폼 차단**: C6(iOS) — in-process 엔진 없이는 불가. 전략적 결정(Tectonic).
- **기능 공백**: C5(SyncTeX) — 네이티브 + VSCode 둘 다 "네이티브하게 느껴지려면" 필수.

## 매핑 한눈에

| 하위문제 | 주 해결 기법(§03) | 단계(§05) |
|---|---|---|
| C1 cold-start | warm engine(§3.3) / Tectonic in-proc(§3.7) | Phase 2 / 3 |
| C2 preamble | `.fmt`(§3.2, pdflatex) / warm engine(§3.3, xelatex) | Phase 2 |
| C3 이미지 | draft(§3.4) / externalize(§3.5) / 프록시(§3.6) | Phase 0 / 1 |
| C4 rerun·bib | latexmk(§3.1) | **Phase 0** |
| C5 SyncTeX | synctex_parser(§3.10) | Phase 0(출력)·1(배선) |
| C6 iOS | Tectonic FFI(§3.7) / SwiftLaTeX-WASM(§3.9, 대체) | Phase 3 |
| C7 PDFKit | viewport 보존 리로드(§4.3) | **Phase 0** |

> 핵심: **C4·C5·C7 의 1차 처리는 Phase 0 에서 기존 두 파일 안에서 끝낼 수 있다.** C1·C2·C6 만 새 백엔드/엔진 작업이 필요하다.
