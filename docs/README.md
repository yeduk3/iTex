# iTex 컴파일 엔진 개선 — 설계 문서 모음

> iTex 의 LaTeX 컴파일러(`Sources/LaTeXCompiler.swift`)와 미리보기(`Sources/PDFPreviewView.swift`)를
> "OSS 라이브러리에 최대한 얹어서 직접 코드는 최소로" 라는 원칙으로 다시 설계하기 위한 조사·설계 문서.
> 6갈래 출처기반 리서치 → 핵심 주장 적대적 검증(adversarial verify) → 종합 의 워크플로 결과를 정리했다.

작성일: 2026-06-26 · 조사 근거: 119개 1차 출처(엔진 매뉴얼·패키지 문서·공식 repo) · 검증: 핵심 주장 18건(확정 6 / 부분확정 12 / 반박 0)

---

## 한 줄 결론

> **"진짜 부분(region) 단위 incremental LaTeX 컴파일은 원리적으로 불가능"** 하다. iTex 가 정당하게 내세울 수 있는, OSS 로 뒷받침되는 이야기는
> **warm engine + figure 캐시 + draft 미리보기 + 불필요한 rerun 생략** 이며, **Tectonic** 을 in-process 코어로 쓰면 유일하게 **iOS 컴파일**이 열린다.
> **SyncTeX** 는 네이티브 에디터와 VSCode 연동 둘 다를 "제대로 동작하게" 만드는 필수 기능이다.
> 가장 빠른 실제 이득(latexmk 교체 + draft 모드 + viewport 보존 PDFKit 리로드)은 **오늘 당장 기존 두 파일 안에서** 적은 코드로 달성 가능.

---

## Baseline 대비 개선 — 무엇을 / 어떤 원리로 / 얼마나

> **Baseline (기존 iTex)**: 매 편집(800ms 디바운스)마다 `xelatex`를 **cold-spawn 전체 재컴파일**. incremental·캐시·SyncTeX 없음, iOS 컴파일 불가, 엔진 1회(`-halt-on-error`)만 돌려 cross-ref/citation **오류**, PDFKit 매번 전체 리로드로 스크롤·줌 소실.
> 측정 조건: Apple silicon mac, 단일 문서, 대형 raster 1장(61–69MB PNG). 수치는 이 세션 실측(파이프라인 검증값).

| 항목 | Baseline | 개선 후 | 원리 (mechanism) | 향상 폭 (실측) |
|---|---|---|---|---|
| **편집 루프 미리보기** (대형 이미지 문서) | 매 편집 전체 재컴파일 ≈ **3.5–5.6s** | FastPreview = draft 주입 ≈ **0.26–0.44s** | `latexmk -usepretex='\PassOptionsToPackage{draft}{graphicx}'` → 이미지 디코드/임베드 스킵, **소스 무수정**, synctex·pagination 유지 | **약 10–17× 빠름** |
| **이미지 임베드 비용** | 6000px raster 원본 그대로 임베드 (엔진은 리샘플 안 함) → PDF **61–69MB** | 표시크기 ~300DPI 프록시 → PDF **1.3–5MB**, 컴파일 3.5s→**1.3s** | `ImageProxyCache`: sips 다운스케일 + content-hash 캐시(`itex --downscale-preview`) | PDF **13–50× 작게** |
| **preamble 재파싱** | 매 run preamble 전체 재확장 | warm `.fmt` 재사용: 빌드 0.29s(1회) / 재사용 **0.22s** | `PrecompiledFormatBackend`(mylatexformat, pdflatex). 줄패딩으로 synctex 줄번호 보존 | heavy preamble 문헌 기준 **~73%↓** (27.66s→7.42s) |
| **불필요한 rerun + cross-ref 정확성** | 엔진 **1회만** → `\ref`/`\cite`/ToC **틀림** | rerun-until-stable + biber 자동 | `LatexmkBackend`: `.fls`/`.fdb_latexmk` 의존성 추적 | **정확성 버그 수정** (속도 아님) |
| **SyncTeX (소스↔PDF)** | 없음 | forward(⌘J) / inverse(⌘-click) 양방향 | `synctex` CLI(`view`/`edit`) + 72dpi 좌표 + PDFKit Y-flip | **신규 기능** |
| **PDFKit 미리보기** | 매 컴파일 전체 리로드 → 스크롤·줌 소실 | scaleFactor + PDFDestination 캡처/복원 | 리로드 전후 viewport 보존, 보이는 페이지만 재래스터화 | **신규(C7 수정)** |
| **iOS 컴파일** | 불가 (`Process` 차단) | in-process Tectonic FFI | Rust `tectonic` crate → C ABI → `TectonicBackend`. macOS E2E 검증(`PDF_BYTES=5110`) | **불가 → 가능** (iOS 크로스컴파일은 rustup 필요) |
| **외부 에디터(VSCode)** | 없음 | `itex` CLI 하나로 LaTeX Workshop/texlab/latexmk 백킹 | latexmk 호환 플래그 + PDF·`.synctex.gz` 출력 | **신규 확장성** |

### 핵심 원리 3가지
1. **"진짜 incremental은 불가" 를 인정하고 우회** — TeX는 전역 가변 상태 + cross-ref가 `.aux`를 거쳐 다음 run에 반영되는 구조라 region 단위 재컴파일이 원리적으로 불가능. 그래서 *warm format + figure/image 캐시 + draft 미리보기 + 불필요 rerun 생략*으로 체감 지연을 줄인다. (docs/01)
2. **Fast vs Final 프로파일 분리** — 편집 루프는 draft(이미지 스킵, cross-ref 근사)로 최저 지연, ⌘B Final은 풀해상도 + rerun-until-stable로 정확성 보장. "real-time preview"에 대한 정직한 답. (docs/04 §4.2)
3. **OSS에 최대한 위임, 직접 코드 최소** — 타입세팅=latexmk/xelatex/Tectonic, 의존성추적=latexmk, sync=synctex CLI, 다운스케일=sips. iTex는 오케스트레이션 + glue만 작성. 같은 엔진 바이너리(`itex` CLI)로 네이티브 앱과 VSCode 둘 다 백킹.

> 정직한 한계: 향상 폭은 *대형 이미지/heavy preamble 문서*에서 큰다. 그래픽 없는 text-heavy 문서는 본문 재타입셋이 지배적이라 이득이 작다. warm `.fmt`는 pdflatex 전용(xelatex는 tex-fast-recompile 경로가 업그레이드 패스). 자세한 벤치 설계는 [docs/05 §A](05-validation-and-plan.md).

---

## 사용자가 보고한 두 문제 — 판정 요약

| # | 사용자 주장 | 판정 | 핵심 |
|---|---|---|---|
| 1 | "큰 이미지 → 컴파일 급격히 느려짐. 이미지를 PDF 에 맞추는 게 병목일 수도. 최신 기법 미적용." | **부분 맞음 / 메커니즘은 일부 오진** | 매 키스트로크마다 이미지를 **재임베드**하는 건 진짜 비용. 하지만 "PDF 에 맞추는" 비용은 포맷마다 다름(JPEG·평범한 PNG·PDF 는 스트림 복사라 쌈). 진짜 빠진 기법은 **재임베드 회피(draft/externalize)** 와 **과대 raster 다운스케일**. 엔진은 이미지를 절대 리샘플 안 함. |
| 2 | "변경분만 빠르게 컴파일하고 싶은데 매번 전체 재컴파일." | **관찰은 사실 / 원하는 기능은 원리적 불가** | TeX 는 전역 가변 상태를 앞으로만 흘려보내는 매크로 확장기 + cross-ref/ToC/citation 이 .aux 를 거쳐 다음 run 에 반영되는 구조라 "바뀐 부분만" 이 성립 불가. 재정의 필요. |

자세한 근거는 [01-problem-definition.md](01-problem-definition.md).

---

## 문서 네비게이션 (요청한 스텝 순서)

| 스텝 | 문서 | 내용 |
|---|---|---|
| 문제 정의 | [01-problem-definition.md](01-problem-definition.md) | 두 문제를 TeX 실행 모델에 비춰 myth vs fact 로 판정 |
| 구체화 | [02-concretization.md](02-concretization.md) | 측정 가능한 하위문제 C1~C7 로 분해(+ 숨은 정확성 버그 2개) |
| 해결방안 | [03-solution-space.md](03-solution-space.md) | 기법 메뉴 10종 — 무엇을 고치고, 효과/비용, 어떤 OSS 가 제공하는지 |
| 개선·확장성 검증 | [04-architecture-and-extensibility.md](04-architecture-and-extensibility.md) | 추천 레이어드 아키텍처(+ macOS/iOS) + SyncTeX 배선 + VSCode 연동 경로 |
| 계획 구상 | [05-validation-and-plan.md](05-validation-and-plan.md) | 벤치마크 검증 계획 + 단계별(Phase 0~4) 구현 계획 + 리스크/오픈질문 |
| 부록 | [appendix-sources-and-verdicts.md](appendix-sources-and-verdicts.md) | 출처 모음 + 적대적 검증에서 나온 정정(correction) 18건 |
| **구현** | [IMPLEMENTATION.md](IMPLEMENTATION.md) | **Phase 0–4 실제 구현 결과 · 파일 맵 · 검증 실측** (코드: `Sources/`, `cli/`, `tectonic-ffi/`, `integration/`) |

---

## 지금 당장 할 수 있는 것 (Phase 0, macOS, 수시간)

기존 `LaTeXCompiler.swift` / `PDFPreviewView.swift` 안에서:

1. **raw 엔진 spawn → `latexmk` 교체** — `latexmk -synctex=1 -interaction=nonstopmode -file-line-error -pdf <file>`.
   올바른 rerun + biber + SyncTeX 출력을 ~10줄로. (현재 iTex 는 엔진을 1회만 돌려 cross-ref/citation 이 **틀림** — 정확성 버그)
2. **Fast-Preview draft 토글** — 미리보기 프로파일에 `\PassOptionsToPackage{draft}{graphicx}` 주입. raster-heavy 문서의 이미지 재임베드 비용 제거.
3. **PDFKit viewport 보존** — 리로드 전 `scaleFactor` + `PDFDestination` 캡처/복원. 매 컴파일마다 스크롤·줌 날아가는 것 수정.

근거: [03-solution-space.md](03-solution-space.md) §3.1·§3.4, [05-validation-and-plan.md](05-validation-and-plan.md) Phase 0.

---

## 핵심 OSS 라이브러리 (직접 코드 최소화)

| 라이브러리 | 역할 | 라이선스 | iTex 결합 방식 |
|---|---|---|---|
| **latexmk** | 의존성 추적·rerun·biber·SyncTeX 출력 | GPL (subprocess) | macOS subprocess |
| **mylatexformat** | preamble 프리컴파일(.fmt) | LPPL | pdflatex 전용(주의) |
| **tex-fast-recompile** | warm engine(preamble 선처리) — **xelatex 호환** | MIT | 기법 차용 또는 번들 |
| **graphicx draft / TikZ external / standalone** | 이미지·figure 캐시 | LPPL | preamble 토글 |
| **Tectonic** (crate) | in-process XeTeX 엔진 → **iOS 가능** | MIT | Rust 정적 lib + C-FFI(XCFramework) |
| **synctex_parser.c** | forward/inverse search | permissive | 두 타깃에 순수 C 벤더링 |
| **PDFKit** | PDF 렌더 | Apple | 이미 사용 중 |
| **Typst / comemo** | (참고) 유일한 진짜 incremental 아키텍처 | Apache-2.0 | 학습용/선택적 2nd 엔진 |

피해야 할 것: **texlab(GPL-3.0)** fork, **SwiftLaTeX(AGPL-3.0)** — 라이선스 리스크. [appendix](appendix-sources-and-verdicts.md#licensing) 참조.
