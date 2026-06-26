# iTex

SwiftUI 기반 LaTeX 에디터 (macOS + iOS) — 실시간 PDF 미리보기, SyncTeX 양방향 검색, 그리고
**기존 대비 편집 루프를 10× 이상 빠르게 만든 컴파일 엔진**.

> 설계·근거·구현 전체 문서: [`docs/`](docs/README.md) · 구현 요약: [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md)

---

## 무엇을 풀었나

LaTeX 에디터의 고질적 두 문제:

1. **큰 이미지가 있으면 컴파일이 급격히 느려** 실시간 미리보기가 불가능하다.
2. **매번 전체 재컴파일** — 바뀐 부분만 빠르게 반영하고 싶다.

조사 결과(1차 출처 119건 + 적대적 검증): **진짜 region 단위 incremental LaTeX은 원리적으로 불가능**하다.
TeX는 전역 가변 상태를 앞으로만 흘려보내는 매크로 확장기이고, cross-reference/ToC/citation은
`.aux`를 거쳐 *다음 run*에 반영되기 때문. 그래서 iTex는 거짓 능력을 주장하는 대신
**warm format + 이미지/figure 캐시 + draft 미리보기 + 불필요한 rerun 생략**으로 체감 지연을 줄인다.

---

## Baseline 대비 개선

**Baseline (기존 iTex):** 매 편집(800ms 디바운스)마다 `xelatex`를 **cold-spawn 전체 재컴파일**.
incremental·캐시·SyncTeX 없음, iOS 컴파일 불가, 엔진 1회(`-halt-on-error`)만 돌려 cross-ref/citation
**오류**, PDFKit 매번 전체 리로드로 스크롤·줌 소실.

> 측정 조건: Apple silicon mac, 단일 문서, 대형 raster 1장(61–69MB PNG). 수치는 실측(파이프라인 검증값).

| 항목 | Baseline | 개선 후 | 원리 (mechanism) | 향상 폭 |
|---|---|---|---|---|
| **편집 미리보기** (대형 이미지) | 전체 재컴파일 ≈ **3.5–5.6s** | draft 주입 ≈ **0.26–0.44s** | `latexmk -usepretex='\PassOptionsToPackage{draft}{graphicx}'` → 이미지 디코드/임베드 스킵, **소스 무수정**, synctex·pagination 유지 | **약 10–17×** |
| **이미지 임베드** | 6000px 원본 그대로 임베드(엔진은 리샘플 안 함) → PDF **61–69MB** | ~300DPI 프록시 → PDF **1.3–5MB**, 컴파일 3.5s→**1.3s** | `ImageProxyCache`: sips 다운스케일 + content-hash 캐시 | PDF **13–50× 작게** |
| **preamble 재파싱** | 매 run 전체 재확장 | warm `.fmt` 재사용 **0.22s** (빌드 0.29s/1회) | `PrecompiledFormatBackend`(mylatexformat, pdflatex). 줄패딩으로 synctex 줄번호 보존 | heavy preamble **~73%↓** |
| **cross-ref 정확성** | 엔진 **1회만** → `\ref`/`\cite`/ToC **틀림** | rerun-until-stable + biber 자동 | `LatexmkBackend`: `.fls`/`.fdb_latexmk` 의존성 추적 | **정확성 버그 수정** |
| **SyncTeX** | 없음 | forward(⌘J)/inverse(⌘-click) | `synctex` CLI + 72dpi 좌표 + PDFKit Y-flip | **신규** |
| **PDFKit 미리보기** | 매 컴파일 스크롤·줌 소실 | scaleFactor + PDFDestination 보존 | 리로드 전후 viewport 캡처/복원 | **신규** |
| **iOS 컴파일** | 불가 (`Process` 차단) | in-process Tectonic FFI (E2E 검증 `PDF_BYTES=5110`) | Rust `tectonic` crate → C ABI → `TectonicBackend` | **불가 → 가능**¹ |
| **VSCode 연동** | 없음 | `itex` CLI 하나로 LaTeX Workshop/texlab/latexmk 백킹 | latexmk 호환 플래그 + PDF·`.synctex.gz` 출력 | **신규** |

¹ macOS 정적 lib + FFI는 검증 완료. iOS 크로스컴파일은 `rustup` 타깃 추가 필요(스크립트·문서 제공).

### 설계 원리 3가지
1. **"진짜 incremental 불가"를 인정하고 우회** — warm format + 캐시 + draft + rerun 생략으로 체감 지연 감소.
2. **Fast vs Final 프로파일 분리** — 편집 루프는 draft(이미지 스킵, cross-ref 근사)로 최저 지연, ⌘B Final은 풀해상도 + 정확성.
3. **OSS에 최대한 위임** — 타입세팅=latexmk/xelatex/Tectonic, sync=synctex CLI, 다운스케일=sips. iTex는 오케스트레이션+glue만. 같은 `itex` 바이너리로 네이티브 앱과 VSCode 둘 다 백킹.

> 한계: 이득은 *대형 이미지/heavy preamble* 문서에서 크다. 그래픽 없는 text-heavy 문서는 본문 재타입셋이
> 지배적이라 작다. warm `.fmt`는 pdflatex 전용(xelatex는 tex-fast-recompile이 업그레이드 패스).

---

## 빠른 시작

**요구사항:** macOS, [XcodeGen](https://github.com/yonaskolb/XcodeGen), MacTeX(또는 `latexmk`+엔진), `synctex`.

```sh
# macOS 앱
xcodegen generate
xcodebuild -project iTex.xcodeproj -scheme iTex-macOS -destination 'platform=macOS' build

# 컴파일 CLI (네이티브 앱 + VSCode 공용 엔진)
cd cli && swift build -c release
.build/release/itex --selfcheck                       # 엔진 검증 (8/8 PASS)
.build/release/itex compile --draft -synctex=1 paper.tex
```

**VSCode 연동:** [`integration/`](integration/README.md)의 LaTeX Workshop / texlab / `.latexmkrc` 스니펫 사용.

**iOS 엔진 빌드:** [`tectonic-ffi/`](tectonic-ffi/README.md) (rustup 타깃 필요).

---

## 구조

```
Sources/            SwiftUI 앱 + 컴파일 엔진
  CompileEngine.swift   CompileBackend 프로토콜 · LatexmkBackend · warm .fmt · ImageProxyCache
  SyncTeX.swift         synctex CLI 래퍼 (forward/inverse, Y-flip)
  LaTeXCompiler.swift   코디네이터 (프로파일·백엔드 선택·SyncTeX 상태)
  TectonicBackend.swift in-process 엔진 (iOS, #if ITEX_TECTONIC)
  PDFPreviewView.swift  viewport 보존 + 하이라이트 + inverse search
cli/                itex CLI (latexmk 호환, 엔진 소스 심볼릭링크 = 단일 소스)
tectonic-ffi/       Rust FFI crate + C 헤더 + XCFramework 빌드 스크립트
integration/        LaTeX Workshop · texlab · latexmkrc 설정
docs/               문제 정의 → 구체화 → 해결방안 → 아키텍처 → 검증·계획 → 구현
```

## 문서

| 문서 | 내용 |
|---|---|
| [docs/README.md](docs/README.md) | 설계 문서 인덱스 + 한 줄 결론 |
| [docs/01–05](docs/README.md#문서-네비게이션-요청한-스텝-순서) | 문제 정의 · 구체화 · 해결방안 · 아키텍처 · 검증/계획 |
| [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) | Phase 0–4 구현 결과 · 파일 맵 · 검증 실측 |
| [docs/appendix](docs/appendix-sources-and-verdicts.md) | 출처 119건 + 적대적 검증 정정 18건 |

## 상태

Phase 0–4 구현 완료. macOS·iOS 앱 빌드 ✅, CLI selfcheck 8/8 ✅, Tectonic FFI macOS E2E ✅.
iOS Tectonic 크로스컴파일만 rustup 타깃 필요(코드·스크립트 준비됨).
