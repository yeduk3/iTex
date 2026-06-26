import Foundation

// Runnable check (ponytail: one self-check that fails if the engine logic breaks).
// Exercises SyncTeX parsing + a real latexmk compile + image proxy end-to-end.

func runSelfcheck() async {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    // 1. parseForward on real `synctex view` output (captured verbatim).
    let viewOut = """
    Page:1
    x:148.158844
    y:156.585541
    h:133.768356
    v:158.522720
    W:343.711060
    H:8.855677
    """
    let fwd = SyncTeXService.parseForward(viewOut, pageHeight: { _ in 792 })
    check("parseForward yields a rect on page 1", fwd.first?.page == 1 && (fwd.first?.rect.width ?? 0) > 300)
    // Y-flip: pdfY = 792 - v - H = 792 - 158.52 - 8.86 ≈ 624.6
    check("parseForward Y-flip correct", abs((fwd.first?.rect.minY ?? 0) - (792 - 158.522720 - 8.855677)) < 0.01)

    // 2. parseInverse on `synctex edit` output shape.
    let editOut = "Output:\nInput:/tmp/doc.tex\nLine:42\nColumn:7\n"
    let inv = SyncTeXService.parseInverse(editOut)
    check("parseInverse reads file+line", inv?.line == 42 && inv?.file == "/tmp/doc.tex")

    // 3. Real compile through LatexmkBackend → pdf + synctex.
    let tmp = FileManager.default.temporaryDirectory.appending(path: "itex-selfcheck")
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let tex = tmp.appending(path: "sc.tex")
    let doc = """
    \\documentclass{article}
    \\begin{document}
    Hello \\textbf{iTex} engine. $E=mc^2$.
    \\end{document}
    """
    try? doc.write(to: tex, atomically: true, encoding: .utf8)
    do {
        let r = try await LatexmkBackend().compile(texPath: tex, workingDir: tmp, engine: .pdflatex, profile: .finalCompile)
        check("latexmk produced a PDF", FileManager.default.fileExists(atPath: r.pdfURL.path))
        check("latexmk produced SyncTeX", r.synctexURL != nil)
    } catch {
        check("latexmk compile (threw: \(error))", false)
    }

    // 3b. Warm precompiled-format backend (pdflatex) — builds .fmt, padded body keeps line numbers.
    let warmTex = tmp.appending(path: "warm.tex")
    let warmDoc = """
    \\documentclass{article}
    \\usepackage{amsmath}
    \\usepackage{lipsum}
    \\begin{document}
    Warm \\(x^2\\). \\lipsum[1]
    \\end{document}
    """
    try? warmDoc.write(to: warmTex, atomically: true, encoding: .utf8)
    do {
        let r = try await PrecompiledFormatBackend().compile(texPath: warmTex, workingDir: tmp, engine: .pdflatex, profile: .fastPreview)
        check("warm backend produced a PDF", FileManager.default.fileExists(atPath: r.pdfURL.path))
        check("warm backend built a reusable .fmt", (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.contains { $0.hasPrefix(".itex-fmt-") } == true)
    } catch {
        check("warm backend compile (threw: \(error))", false)
    }

    // 4. ImageProxyCache shrinks a large raster (skip if we can't synthesize one).
    let big = tmp.appending(path: "big.png")
    let mk = Process(); mk.executableURL = URL(filePath: "/usr/bin/env")
    mk.arguments = ["magick", "-size", "3000x2000", "plasma:fractal", big.path]
    mk.standardError = FileHandle.nullDevice
    try? mk.run(); mk.waitUntilExit()
    if FileManager.default.fileExists(atPath: big.path),
       let origSize = try? FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int, origSize > 0 {
        if let proxy = ImageProxyCache.proxy(for: big, maxDim: 600, cacheDir: tmp.appending(path: ".cache"), minBytes: 1) {
            let pSize = (try? FileManager.default.attributesOfItem(atPath: proxy.path)[.size] as? Int) ?? .max
            check("ImageProxyCache shrinks raster", (pSize ?? .max) < origSize)
        } else {
            check("ImageProxyCache returned a proxy", false)
        }
    } else {
        print("SKIP ImageProxyCache (magick unavailable)")
    }

    print(failures == 0 ? "\nselfcheck: ALL PASS" : "\nselfcheck: \(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
