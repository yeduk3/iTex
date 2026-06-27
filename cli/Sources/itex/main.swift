import Foundation

// itex — minimal LaTeX compile CLI backing iTex's engine (docs/04 §4.5).
// Drop-in enough for a LaTeX Workshop tool / texlab build.executable: it accepts latexmk-style
// flags, emits PDF + .synctex.gz into the out dir, and reuses the same backend as the app.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    itex — LaTeX compile CLI (backs iTex's engine; see docs/)
    usage:
      itex compile [--engine xelatex|pdflatex|lualatex] [--draft]
                   [--downscale-preview] [-outdir=DIR] [-synctex=1] FILE.tex
      itex --selfcheck
    Unknown latexmk-style flags are ignored, so it slots into existing recipes.

    """.utf8))
    exit(2)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { usage() }

if cmd == "--selfcheck" {
    await runSelfcheck()
    exit(0)
}
if cmd == "--warmbench" {
    await runWarmBench(Array(argv.dropFirst()))
    exit(0)
}
guard cmd == "compile" else { usage() }

// MARK: - parse latexmk-ish flags leniently

var engine = TexEngine.xelatex
var profile = CompileProfile.finalCompile
var downscale = false
var outdir: String?
var file: String?

var i = 1
while i < argv.count {
    let a = argv[i]
    if a == "--engine", i + 1 < argv.count { i += 1; engine = TexEngine(rawValue: argv[i]) ?? .xelatex }
    else if a == "--draft" { profile = .fastPreview }
    else if a == "--downscale-preview" { downscale = true }
    else if a == "-outdir" || a == "--outdir", i + 1 < argv.count { i += 1; outdir = argv[i] }
    else if a.hasPrefix("-outdir=") { outdir = String(a.dropFirst("-outdir=".count)) }
    else if a == "-pdf" { engine = .pdflatex }
    else if a == "-pdfxe" { engine = .xelatex }
    else if a == "-pdflua" { engine = .lualatex }
    else if !a.hasPrefix("-") { file = a }   // the .tex file; ignore all other -flags
    i += 1
}
guard let file, let texPath = resolve(file) else { usage() }
let sourceDir = texPath.deletingLastPathComponent()

do {
    var compileTex = texPath
    var workingDir = sourceDir

    // --downscale-preview: compile in a temp dir with downscaled copies of the images so a
    // photo-heavy doc previews fast (docs/03 §3.6). ponytail: single-file docs only.
    if downscale {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "itex-cli-\(texPath.lastPathComponent)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = try String(contentsOf: texPath, encoding: .utf8)
        let copy = tmp.appending(path: texPath.lastPathComponent)
        try src.write(to: copy, atomically: true, encoding: .utf8)
        var shrunk = 0
        for img in includedImages(in: src, baseDir: sourceDir) {
            let dst = tmp.appending(path: img.lastPathComponent)
            if let proxy = ImageProxyCache.proxy(for: img, cacheDir: tmp.appending(path: ".cache")) {
                try? FileManager.default.copyItem(at: proxy, to: dst); shrunk += 1
            } else {
                try? FileManager.default.copyItem(at: img, to: dst)
            }
        }
        FileHandle.standardError.write(Data("itex: downscaled \(shrunk) image(s) for preview\n".utf8))
        compileTex = copy
        workingDir = tmp
    }

    let backend = LatexmkBackend()
    let result = try await backend.compile(texPath: compileTex, workingDir: workingDir, engine: engine, profile: profile)

    // Place outputs where the caller expects them.
    let dest = outdir.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? sourceDir
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let base = texPath.deletingPathExtension().lastPathComponent
    place(result.pdfURL, into: dest, named: base + ".pdf")
    if let syn = result.synctexURL { place(syn, into: dest, named: base + ".synctex.gz") }
    print("itex: wrote \(dest.appending(path: base + ".pdf").path)")
    exit(0)
} catch {
    FileHandle.standardError.write(Data("itex: build failed\n\((error as? CompilerError)?.errorDescription ?? "\(error)")\n".utf8))
    exit(1)
}

// MARK: - helpers

func resolve(_ path: String) -> URL? {
    let u = URL(filePath: path)
    let abs = u.path.hasPrefix("/") ? u : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: path)
    return FileManager.default.fileExists(atPath: abs.path) ? abs : nil
}

func place(_ src: URL, into dir: URL, named name: String) {
    let dst = dir.appending(path: name)
    // Same file (incl. /tmp ↔ /private/tmp symlink aliasing) → nothing to do.
    if src.resolvingSymlinksInPath().path == dst.resolvingSymlinksInPath().path { return }
    try? FileManager.default.removeItem(at: dst)
    try? FileManager.default.copyItem(at: src, to: dst)
}

/// Filenames referenced by \includegraphics, resolved against baseDir (best-effort).
func includedImages(in source: String, baseDir: URL) -> [URL] {
    let re = try! NSRegularExpression(pattern: #"\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}"#)
    let ns = source as NSString
    var out: [URL] = []
    re.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
        guard let m, let r = Range(m.range(at: 1), in: source) else { return }
        let name = String(source[r])
        for candidate in [name, name + ".png", name + ".jpg", name + ".jpeg", name + ".pdf"] {
            let u = baseDir.appending(path: candidate)
            if FileManager.default.fileExists(atPath: u.path) { out.append(u); break }
        }
    }
    return out
}
