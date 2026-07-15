import Foundation

// Runnable deterministic check for the shared compiler and two-stage image-preview primitives.

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

    // 3. Real Final Build backend compile → pdf + synctex + recorder.
    let tmp = FileManager.default.temporaryDirectory.appending(path: "itex-selfcheck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
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
        let out = tmp.appending(path: "plain-out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = try await LatexmkBackend().compile(texPath: tex, cwd: tmp, outDir: out,
                                                  engine: .pdflatex, profile: .finalCompile)
        check("latexmk produced a PDF", FileManager.default.fileExists(atPath: r.pdfURL.path))
        check("latexmk produced SyncTeX", r.synctexURL != nil)
        check("latexmk produced recorder dependencies", r.recorderURL != nil)
    } catch {
        check("latexmk compile (threw: \(error))", false)
    }

    // 4. ImageProxyCache: shrink, preserve natural dimensions, reuse, then invalidate on mtime.
    let project = tmp.appending(path: "project")
    let assets = project.appending(path: "assets")
    let sections = project.appending(path: "sections")
    try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sections, withIntermediateDirectories: true)
    let big = assets.appending(path: "big.png")
    let mk = Process(); mk.executableURL = URL(filePath: "/usr/bin/env")
    mk.arguments = ["magick", "-size", "3000x2000", "plasma:fractal", big.path]
    mk.standardError = FileHandle.nullDevice
    try? mk.run(); mk.waitUntilExit()
    if FileManager.default.fileExists(atPath: big.path),
       let origSize = try? FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int, origSize > 0 {
        let cache = tmp.appending(path: ".cache")
        if let proxy = ImageProxyCache.proxy(for: big, maxDim: 600, cacheDir: cache, minBytes: 1) {
            let pSize = (try? FileManager.default.attributesOfItem(atPath: proxy.path)[.size] as? Int) ?? Int.max
            check("ImageProxyCache shrinks raster", pSize < origSize)
            let reused = ImageProxyCache.proxy(for: big, maxDim: 600, cacheDir: cache, minBytes: 1)
            check("ImageProxyCache reuses unchanged image", reused == proxy)
            if let before = ImageProxyCache.metadata(for: big), let after = ImageProxyCache.metadata(for: proxy) {
                let naturalBefore = before.pixelWidth / before.dpiWidth
                let naturalAfter = after.pixelWidth / after.dpiWidth
                check("proxy preserves aspect ratio", abs(before.pixelWidth / before.pixelHeight - after.pixelWidth / after.pixelHeight) < 0.01)
                check("proxy preserves natural width", abs(naturalBefore - naturalAfter) < max(0.05, naturalBefore * 0.01))
            } else {
                check("proxy metadata readable", false)
            }
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                                   ofItemAtPath: big.path)
            let invalidated = ImageProxyCache.proxy(for: big, maxDim: 600, cacheDir: cache, minBytes: 1)
            check("ImageProxyCache invalidates changed image", invalidated != nil && invalidated != proxy)
        } else {
            check("ImageProxyCache returned a proxy", false)
        }
    } else {
        print("SKIP ImageProxyCache (magick unavailable)")
    }

    // 5. Recorder-based project plan supports graphicspath, subdirectory input and omitted ext.
    let main = project.appending(path: "main.tex")
    let body = sections.appending(path: "body.tex")
    let mainSource = """
    \\documentclass{article}
    \\usepackage{graphicx}
    \\graphicspath{{assets/}}
    \\begin{document}
    \\input{sections/body}
    \\end{document}
    """
    let bodySource = "\\includegraphics[width=.45\\linewidth]{big}\\par\\includegraphics{big.png}\n"
    try? mainSource.write(to: main, atomically: true, encoding: .utf8)
    try? bodySource.write(to: body, atomically: true, encoding: .utf8)
    let fls = tmp.appending(path: "draft.fls")
    try? "INPUT \(main.path)\nINPUT \(body.path)\nINPUT \(big.path)\n".write(to: fls, atomically: true, encoding: .utf8)
    let plan = ImagePreviewProject.plan(source: mainSource, sourceURL: main, recorderURL: fls)
    check("image plan detects graphics", plan.hasGraphics && plan.imageFiles.contains(big))
    check("image plan stays in project mirror", !plan.requiresOriginalTreeFallback)
    let noImagePlan = ImagePreviewProject.plan(source: "\\documentclass{article}\\begin{document}x\\end{document}",
                                               sourceURL: main, recorderURL: nil)
    check("image-free document skips second pass", !noImagePlan.hasGraphics)

    // 6. Compile an image mirror and verify draft/images write and publish to distinct paths.
    if FileManager.default.fileExists(atPath: big.path) {
        do {
            let draftStage = tmp.appending(path: "generation/7/draft")
            let draftWork = draftStage.appending(path: "work")
            try FileManager.default.createDirectory(at: draftWork, withIntermediateDirectories: true)
            let draftStarted = Date()
            let draftRaw = try await LatexmkBackend().compile(texPath: main, cwd: project, outDir: draftWork,
                                                              engine: .pdflatex, profile: .fastPreview)
            let draft = try CompilePublication.publish(draftRaw, into: draftStage)
            let draftDuration = -draftStarted.timeIntervalSinceNow
            let imageStage = tmp.appending(path: "generation/7/images")
            let imageStarted = Date()
            let enhanced = try await ImagePreviewProject.compile(
                plan: ImagePreviewProject.plan(source: mainSource, sourceURL: main, recorderURL: draft.recorderURL),
                source: mainSource, sourceURL: main, engine: .pdflatex,
                stageDir: imageStage, cacheDir: tmp.appending(path: ".cache"), draftResult: draft
            )
            let imageDuration = -imageStarted.timeIntervalSinceNow
            check("draft and image outputs are isolated", draft.pdfURL.path != enhanced.result.pdfURL.path
                  && draft.pdfURL.path.contains("/draft/") && enhanced.result.pdfURL.path.contains("/images/"))
            check("PDFKit result is immutable publication", enhanced.result.pdfURL.path.contains("/result/"))
            check("image mirror compiled graphicspath/subdir", FileManager.default.fileExists(atPath: enhanced.result.pdfURL.path))
            let draftInfo = await Subprocess.run(["pdfinfo", draft.pdfURL.path], cwd: tmp)
            let imageInfo = await Subprocess.run(["pdfinfo", enhanced.result.pdfURL.path], cwd: tmp)
            func layoutSignature(_ output: String) -> String {
                output.components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("Pages:") || $0.hasPrefix("Page size:") }
                    .joined(separator: "|")
            }
            check("explicit-width and natural-size layout stays stable",
                  draftInfo.status == 0 && imageInfo.status == 0
                  && layoutSignature(draftInfo.output) == layoutSignature(imageInfo.output))
            print(String(format: "TIMING draft=%.3fs imagePreview=%.3fs proxies=%d",
                         draftDuration, imageDuration, enhanced.proxyCount))
        } catch {
            check("image mirror compile (threw: \(error))", false)
        }
    }

    // 7. Independent image work must not terminate the draft owner's parked warm process.
    if FileManager.default.fileExists(atPath: big.path) {
        let resources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources").path
        let draftOwner = DraftPreviewCompiler()
        do {
            let warmRoot = tmp.appending(path: "warm-owner")
            let first = try await draftOwner.compile(
                source: mainSource, sourceURL: main, engine: .pdflatex, warmRoot: warmRoot,
                stageDir: tmp.appending(path: "generation/8/draft"), resources: resources, useWarm: true
            )
            _ = try await ImagePreviewProject.compile(
                plan: ImagePreviewProject.plan(source: mainSource, sourceURL: main, recorderURL: first.recorderURL),
                source: mainSource, sourceURL: main, engine: .pdflatex,
                stageDir: tmp.appending(path: "generation/8/images-independent"),
                cacheDir: tmp.appending(path: ".cache"), draftResult: first
            )
            let second = try await draftOwner.compile(
                source: mainSource + "\n% body-only save\n", sourceURL: main, engine: .pdflatex,
                warmRoot: warmRoot, stageDir: tmp.appending(path: "generation/9/draft"),
                resources: resources, useWarm: true
            )
            check("image preview leaves draft WarmEngine alive", second.usedWarmEngine)
            check("rapid draft generations publish separately", first.pdfURL.path != second.pdfURL.path)
        } catch {
            check("warm/image independence (threw: \(error))", false)
        }
        await draftOwner.shutdown()
    }

    // 8. A corrupt oversized raster fails proxying safely (mirror logic keeps its original link).
    let corrupt = assets.appending(path: "corrupt.png")
    try? Data(repeating: 0x55, count: 2_100_000).write(to: corrupt)
    check("proxy failure returns fallback signal", ImageProxyCache.proxy(for: corrupt, cacheDir: tmp.appending(path: ".cache")) == nil)

    print(failures == 0 ? "\nselfcheck: ALL PASS" : "\nselfcheck: \(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
