import Foundation

// itex --warmbench FILE.tex [resourcesDir]
// Runtime verification of the real WarmEngine actor (CompileEngine.swift, symlinked into the CLI):
// measures a COLD pass (preamble+body, no park benefit) vs a WARM pass (body-only, preamble already
// loaded in RAM) on a real document, and confirms warm emits SyncTeX recording the build copy.
func runWarmBench(_ args: [String]) async {
    guard let file = args.first, let fileURL = resolve(file) else {
        FileHandle.standardError.write(Data("usage: itex --warmbench FILE.tex [resourcesDir]\n".utf8)); exit(2)
    }
    let resources = args.count > 1 ? args[1] : "/Users/gyu/codes/iTex/Resources"
    let source = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    let dir  = fileURL.deletingLastPathComponent()
    let base = fileURL.deletingPathExtension().lastPathComponent
    let buildTex = dir.appending(path: "\(base)-itexbuild.tex")
    try? Data(source.utf8).write(to: buildTex)

    // Engine: magic comment if present, else heuristic (faithful enough for the bench).
    let engine: TexEngine = {
        if let r = source.range(of: #"(?im)^\s*%\s*!TE?X\s+(?:TS-)?program\s*=\s*([a-z]+)"#, options: .regularExpression) {
            let v = source[r].lowercased()
            if v.contains("lua") { return .lualatex }
            if v.contains("pdf") { return .pdflatex }
            return .xelatex
        }
        if source.contains("\\directlua") || source.contains("luatexja") { return .lualatex }
        return .xelatex
    }()
    let preamble = source.components(separatedBy: "\\begin{document}").first ?? source
    let hash = stableHash(preamble)
    let warm = WarmEngine()
    func took(_ start: Date) -> String { String(format: "%.2fs", -start.timeIntervalSinceNow) }

    print("warmbench: \(fileURL.lastPathComponent)  engine=\(engine.rawValue)")
    print("fastrecompile.sty: \(FileManager.default.fileExists(atPath: resources + "/fastrecompile.sty") ? "found" : "MISSING") (\(resources))")

    // COLD: arm then feed immediately — the fed filename waits in the pipe, so the timed feed
    // includes the whole preamble (CJK fonts, theme) + body = a full single-pass compile.
    await warm.arm(buildTex: buildTex, engine: engine, preambleHash: hash, workingDir: dir, resources: resources)
    var t = Date()
    let cold = await warm.tryCompile(buildTex: buildTex, engine: engine, preambleHash: hash, workingDir: dir)
    let coldT = took(t)
    print("COLD (preamble+body): \(coldT)   pdf=\(cold != nil)  synctex=\(cold?.synctexURL != nil)")

    // WARM: arm, let the preamble load off the clock, then feed → only the body is typeset.
    await warm.arm(buildTex: buildTex, engine: engine, preambleHash: hash, workingDir: dir, resources: resources)
    try? await Task.sleep(for: .seconds(6))
    t = Date()
    let warmR = await warm.tryCompile(buildTex: buildTex, engine: engine, preambleHash: hash, workingDir: dir)
    let warmT = took(t)
    print("WARM (body only):     \(warmT)   pdf=\(warmR != nil)  synctex=\(warmR?.synctexURL != nil)")
    await warm.kill()

    // SyncTeX must record the build copy so forward search matches.
    if let syn = warmR?.synctexURL {
        let q = await SyncTeXService.forward(line: 137, texFile: buildTex, pdf: warmR!.pdfURL, pageHeight: { _ in 792 })
        print("synctex: \(syn.lastPathComponent)  forward(line137)->\(q.count) node(s)")
    }
    print(cold != nil && warmR != nil ? "RESULT: warm path works ✅" : "RESULT: FAILED ❌  (see log above)")
    exit(cold != nil && warmR != nil ? 0 : 1)
}
