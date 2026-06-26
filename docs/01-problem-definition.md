# 01. 문제 정의 — myth vs fact

> 사용자가 보고한 두 문제를 TeX 의 실제 실행 모델에 비춰 "진짜 문제 / 오진 / 원리적 불가" 로 판정한다.
> 모든 판정은 1차 출처(엔진·패키지 매뉴얼, 공식 repo)와 적대적 검증을 거쳤다. 정정 내역은 [부록](appendix-sources-and-verdicts.md) 참조.

---

## 문제 (1): "큰 이미지 → 컴파일 급격히 느림. 이미지를 PDF 포맷에 맞추는 게 병목일지도. 빠른/발전된 기법 미적용일 수 있음."

### 판정: **진짜 병목 맞음. 단 메커니즘은 일부 오진이고 포맷 의존적.**

**사실 (Fact)**
- `graphicx` 는 cross-run 캐시를 전혀 두지 않는다. 매 컴파일마다 이미지를 다시 찾아서 새로 쓰여지는 PDF 에 다시 emit 한다. iTex 는 800ms 디바운스된 매 키스트로크마다 전체 재컴파일(`LaTeXCompiler.swift:29-36`)하므로 **이미지가 매 편집마다 재임베드**된다. 반복되는 진짜 비용이다. ([graphicx manual](https://texdoc.org/serve/graphicx.pdf/0))

**오진 정정 — "이미지를 PDF 에 맞추는" 건 균일한 단일 비용이 아니다.** 비용은 이미지 포맷과 엔진 경로에 따라 갈리며, 일반적인 "fit/embed" 단계가 아니다:
- **JPEG**: DCT 비트스트림을 `/DCTDecode` XObject 로 **그대로 복사**(재압축 없음). 커도 쌈. ([Hoekwater, comp.text.tex](https://groups.google.com/g/comp.text.tex/c/LGZIaX5tbYU))
- **포함된 PDF**: image XObject 를 그대로 복사. raster 재압축 없음.
- **PNG**: **무조건 느린 게 아니다.** pdfTeX ~1.40(2007, Henkel `copy_png`, 현재 TeX Live `writepng.c` 에 그대로 존재) 이후로, *non-interlaced grayscale/RGB · alpha 없음 · tRNS 없음 · gamma==1 · PDF≥1.2 대상* PNG 는 `/FlateDecode` XObject 로 **스트림 그대로 복사**된다 — JPEG 와 똑같이 쌈. inflate→unfilter→re-deflate 의 풀 비용은 **palette/indexed, alpha(SMask), tRNS, interlaced, gamma≠1** PNG 에서만 발생. ([texlive-source writepng.c](https://github.com/TeX-Live/texlive-source/blob/trunk/texk/web2c/pdftexdir/writepng.c))
- `graphicx` 는 **driver-독립 프런트엔드**일 뿐. 실제 읽기/임베드는 엔진/드라이버가 함(pdftex.def → `\pdfximage`; XeTeX 는 xdvipdfmx). 그래서 "graphicx 가 이미지를 PDF 에 맞춘다" 는 부정확. ([graphicx manual](https://texdoc.org/serve/graphicx.pdf/0))
- **엔진은 과대 raster 를 절대 리샘플하지 않는다** — 6000px 이미지를 5cm 로 줄여 써도 6000px 전부를 임베드한다. 이게 진짜 "최신 기법 미적용" 의 빈틈이다. 아무것도 이미지를 다운샘플/프록시하지 않는다. ([dvipdfmx docs](https://tug.org/dvipdfmx/doc/dvipdfmx/dvipdfmx.pdf))

**iTex 에 대한 결론**
사용자의 직관("이미지 때문에 느리고, 똑똑한 처리를 안 한다")은 **결과적으로 맞다**. 하지만 해법은 "더 빨리 임베드" 가 아니라:
1. **매 키스트로크마다 재임베드하지 않기** (draft 모드 / externalized cached figure)
2. **과대 raster 를 미리 스케일/프록시** (엔진이 안 해주므로)

iTex 의 기본 엔진은 **xelatex** 이고 이미지는 xdvipdfmx 를 탄다. 가정하기 전에 **문서별로 draft-vs-normal 타이밍 테스트**로 병목을 확인할 것(아래 진단법 참조).

> ⚠️ 검증에서 나온 주의: "느린 컴파일의 #1 원인은 과대 이미지" 라는 강한 프레임은 과장이다. 인용된 출처들끼리도 의견이 갈렸다(누구는 TikZ/PGF, 누구는 monolithic .tex 구조를 1순위로 지목). draft-vs-normal 테스트는 **유용하지만 불완전한** 진단이다(전역 `[draft]` 는 다른 패키지에도 영향을 주고, **TikZ/PGF 그림은 계산물이라 draft 로 안 잡힘** — `\tikzexternalize` 가 필요). 따라서 **문서별로 확인**해야 한다. ([부록 PARTIAL 항목](appendix-sources-and-verdicts.md))

### 진단법 (문서별로 병목 확인)
```latex
% normal 컴파일 시간 측정 후, preamble 에 아래 추가하고 재측정
\usepackage[draft]{graphicx}   % 이미지 디코드/임베드 스킵, 크기 placeholder만
```
- draft 에서 크게 빨라짐 → 외부 **이미지 임베드**가 병목 (→ §3.4 draft, §3.6 프록시)
- draft 에서 별 차이 없음 → 병목은 다른 곳(TikZ 계산, preamble 로딩, 다중 pass, fontspec, biber). (→ §3.2/§3.3 warm, §3.5 externalize)

---

## 문제 (2): "변경분만(incremental) 컴파일하고 싶은데 매번 전체 재컴파일로 보임."

### 판정: **관찰은 사실. 원하는 기능은 mainstream TeX 에서 원리적으로 불가능. 반드시 재정의해야 함.**

**전체 재컴파일이 본질적인 이유**
- "TeX 는 단일 forward pass" 라는 흔한 설명은 단순화다(한 run 안에서 expansion 과 execution 은 **교차 진행**되고, page builder/`\output` 루틴은 피드백 루프를 이룬다 — [TeX by Topic](https://texdoc.org/serve/texbytopic/0)).
- **진짜 결정적 이유는 엔진이 아니라 문서(document) 레벨에 있다.** cross-reference(`\label`/`\ref`), `\tableofcontents`/LoF/LoT, 페이지 번호, citation 은 문서 전체를 읽은 뒤에야 알 수 있다. LaTeX 는 이걸 한 run **동안** `.aux`/`.toc`/`.lof` 에 쓰고, **다음 run 시작**에 읽어들인다("Rerun to get cross-references right" 루프). 참고문헌은 별도 서브파이프라인 — `.bbl` 은 LaTeX pass 가 아니라 **외부 프로그램**(BibTeX/Biber)이 `.aux` 를 읽어 만든다. ([latexref Cross-references](https://latexref.xyz/Cross-references.html))
- **참고**: TeX 는 expansion 레벨에서도 Turing-complete(Alan Jeffrey, "Lists in TeX's mouth", TUGboat 11:2, 1990 — 매크로 확장만으로 람다 계산 구현). 따라서 출력은 일반적으로 소스의 지역적 관찰만으로 정적 예측 불가. 다만 실무에서 "실제로 돌려봐야 하는" 지배적 이유는 Turing-completeness 보다 **전역·순서 의존 가변 상태**(catcode, counter, register, `\parshape`, 비동기 page builder, float 배치, cross-ref 다중 pass)다. ([부록 정정](appendix-sources-and-verdicts.md))

**"바뀐 영역만 재컴파일" 이 불건전한 이유**
지역 편집 하나가 전역 가변 상태를 교란할 수 있다(한 문단 reflow → float 이동 → 페이지 번호 이동 → reference 재번호). TeX 는 앞으로만 흐르는 상태(catcode, counter, register, galley, page builder)를 들고 있다. **어떤 mainstream 툴도 본문 region 단위 재컴파일을 시도하지 않으며**, 일반적으로 정확하게 만들 수 없다.

**그렇다면 iTex 에서 "incremental" 이 정직하게 뜻할 수 있는 것** — 진짜 region-incremental 은 아니지만 OSS 로 뒷받침되는 4가지 대체재:
1. **Precompiled preamble** (`mylatexformat` 의 `.fmt`) — 무거운 preamble 을 바이너리 메모리 덤프로 동결. ([mylatexformat](https://ctan.org/pkg/mylatexformat))
2. **Warm pre-started engine** (`tex-fast-recompile`) — 편집 idle 시간에 변하지 않는 preamble 까지 엔진을 미리 돌려두고, 저장 시 본문만 먹임. ([tex-fast-recompile](https://github.com/user202729/tex-fast-recompile))
3. **의존성 기반 rerun 생략** (`latexmk`) — *전체* rerun 이 몇 번 필요한지 판단해 불필요분 생략(incremental 컴파일러 아님). ([latexmk man](https://manpages.debian.org/testing/latexmk/latexmk.1.en.html))
4. **Figure 단위 캐시** (TikZ `external` / `standalone`) — 유일하게 진짜 본문 콘텐츠 캐싱. 각 그림을 MD5 키로 한 번만 PDF 로 컴파일해 재사용. ([tikz external](https://tikz.dev/library-external))

> **UX/마케팅에 드러낼 정직한 프레이밍**: "Incremental LaTeX" 은 존재하지 않는다. iTex 가 제공하는 건 *warm-engine + cached-figures + skip-unneeded-reruns* 이며, 이는 거짓 능력을 주장하지 않으면서 edit-to-preview 지연을 크게 줄인다.

---

## 두 문제 뒤에 숨은 정확성(correctness) 버그 2개

속도 불만 안에 사실 **정확성 버그**가 숨어 있다 — 같이 고쳐야 한다:

- **C4**: iTex 는 엔진을 `-halt-on-error` 로 **1회만** 돌린다(`LaTeXCompiler.swift:83-88`). 그래서 cross-ref/citation/ToC 가 종종 **틀린다**(rerun 없음, biber 없음). 속도가 아니라 정확성 문제다. latexmk 가 `.aux` 안정될 때까지 재실행해 해결.
- **C7**: `PDFPreviewView.swift:40-42`/`:57-59` 가 매 `compilationID` 변경마다 `view.document = PDFDocument(url:)` 로 **전체 리로드** → 스크롤 위치·줌이 매번 날아감.

→ 분해는 [02-concretization.md](02-concretization.md).
