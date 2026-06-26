import Foundation

// MARK: - Profiles & results

/// Two compile profiles (docs/04 §4.2). FastPreview trades cross-ref exactness for latency.
enum CompileProfile {
    case fastPreview    // draft images, fewest reruns — lowest edit-to-preview latency
    case finalCompile   // full-res images, rerun-until-stable, biber — correct numbering
}

struct CompileResult {
    let pdfURL: URL
    let synctexURL: URL?
    let log: String
}

/// One compile strategy. macOS backends shell out (latexmk / warm pdflatex); the iOS backend
/// runs Tectonic in-process. Cross-platform so iOS can conform (docs/04 §4.1).
protocol CompileBackend {
    /// `texPath` is already written to disk. Compile it in `workingDir`.
    func compile(texPath: URL, workingDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult
}

#if os(macOS)

/// Deterministic across processes (unlike `String.hashValue`, which is per-process randomized),
/// so the .fmt and image-proxy caches actually persist between app launches. FNV-1a/64.
func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 36)
}

// MARK: - Subprocess helper (drains pipe concurrently to avoid >64KB deadlock)

/// Thread-safe byte accumulator for draining a subprocess pipe off the reader thread.
final class OutputSink {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func string() -> String { lock.lock(); let d = data; lock.unlock(); return String(decoding: d, as: UTF8.self) }
}

enum Subprocess {
    static let texPATH = "/opt/homebrew/bin:/Library/TeX/texbin:/usr/local/bin:/usr/bin"

    static func run(_ args: [String], cwd: URL, launch: String = "/usr/bin/env") async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(filePath: launch)
            p.currentDirectoryURL = cwd
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = texPATH + ":" + (env["PATH"] ?? "")
            p.environment = env

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let handle = pipe.fileHandleForReading

            // Drain incrementally so a large log can't block the child on a full pipe.
            let sink = OutputSink()
            handle.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { sink.append(d) }
            }
            p.terminationHandler = { proc in
                handle.readabilityHandler = nil
                sink.append((try? handle.readToEnd()) ?? Data())
                cont.resume(returning: (proc.terminationStatus, sink.string()))
            }
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

// MARK: - latexmk backend (default — correct reruns + biber + SyncTeX, docs/03 §3.1)

struct LatexmkBackend: CompileBackend {
    func compile(texPath: URL, workingDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult {
        let base = texPath.deletingPathExtension().lastPathComponent

        var args = [
            "latexmk",
            engine.latexmkFlag,
            "-synctex=1",
            "-interaction=nonstopmode",
            "-file-line-error",
            "-outdir=" + workingDir.path,
        ]
        if profile == .fastPreview {
            // Skip image decode/embed without touching the user's source (docs/03 §3.4, verified).
            args.append("-usepretex=\\PassOptionsToPackage{draft}{graphicx}")
        }
        args.append(texPath.lastPathComponent)

        let r = await Subprocess.run(args, cwd: workingDir)
        let pdf = workingDir.appending(path: base + ".pdf")
        let syn = workingDir.appending(path: base + ".synctex.gz")
        guard r.status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw CompilerError.buildFailed(r.output)
        }
        let synURL = FileManager.default.fileExists(atPath: syn.path) ? syn : nil
        return CompileResult(pdfURL: pdf, synctexURL: synURL, log: r.output)
    }
}

// MARK: - Warm precompiled-format backend (pdflatex only, docs/03 §3.2)
//
// ponytail: pdflatex-only by nature (xelatex/lualatex can't dump fontspec state — verified
// against latexmk's precompile-preamble rcfile). Splits preamble→.fmt, pads the body file so
// SyncTeX line numbers stay correct. Trades the .synctex (returns nil) for latency; SyncTeX
// still comes from the latexmk path. Upgrade path: tex-fast-recompile warm process for xelatex.

struct PrecompiledFormatBackend: CompileBackend {
    func compile(texPath: URL, workingDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult {
        guard engine == .pdflatex else {
            // Not applicable — caller should have routed elsewhere; fall back to latexmk.
            return try await LatexmkBackend().compile(texPath: texPath, workingDir: workingDir, engine: engine, profile: profile)
        }
        let source = (try? String(contentsOf: texPath, encoding: .utf8)) ?? ""
        let lines = source.components(separatedBy: "\n")
        guard let beginIdx = lines.firstIndex(where: { $0.contains("\\begin{document}") }) else {
            return try await LatexmkBackend().compile(texPath: texPath, workingDir: workingDir, engine: engine, profile: profile)
        }

        let base = texPath.deletingPathExtension().lastPathComponent
        let preamble = lines[..<beginIdx].joined(separator: "\n")
        let fmtName = ".itex-fmt-" + stableHash(preamble)
        let fmtFile = workingDir.appending(path: fmtName + ".fmt")

        // Build the format only when the preamble changed.
        if !FileManager.default.fileExists(atPath: fmtFile.path) {
            // Clear stale formats from earlier preambles.
            if let old = try? FileManager.default.contentsOfDirectory(atPath: workingDir.path) {
                for f in old where f.hasPrefix(".itex-fmt-") { try? FileManager.default.removeItem(at: workingDir.appending(path: f)) }
            }
            let preFile = workingDir.appending(path: fmtName + "-pre.tex")
            try (preamble + "\n\\endofdump\n").write(to: preFile, atomically: true, encoding: .utf8)
            let mk = await Subprocess.run(
                ["pdflatex", "-ini", "-jobname=" + fmtName, "&pdflatex", "mylatexformat.ltx", preFile.lastPathComponent],
                cwd: workingDir)
            guard FileManager.default.fileExists(atPath: fmtFile.path) else {
                _ = mk
                return try await LatexmkBackend().compile(texPath: texPath, workingDir: workingDir, engine: engine, profile: profile)
            }
        }

        // Body file: line 1 = format reference, blank-pad so \begin{document} keeps its original
        // line number (→ SyncTeX line mapping unchanged), then the body verbatim.
        let bodyName = ".itex-body-" + base
        let padding = String(repeating: "\n", count: max(0, beginIdx - 1))
        let body = "%&" + fmtName + "\n" + padding + lines[beginIdx...].joined(separator: "\n")
        let bodyFile = workingDir.appending(path: bodyName + ".tex")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)

        var args = ["pdflatex", "-interaction=nonstopmode", "-file-line-error", "-jobname=" + base]
        if profile == .fastPreview { args.append("-synctex=0") }
        args.append(bodyFile.lastPathComponent)

        let r = await Subprocess.run(args, cwd: workingDir)
        let pdf = workingDir.appending(path: base + ".pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw CompilerError.buildFailed(r.output)
        }
        return CompileResult(pdfURL: pdf, synctexURL: nil, log: r.output)
    }
}

// MARK: - Image proxy cache (docs/03 §3.6) — downscale oversized rasters, cached by content.
//
// ponytail: live source-substitution via \graphicspath proved unreliable under latexmk, so this
// utility is wired into the `itex` CLI's temp-dir path, not the live editor profile (FastPreview
// uses draft instead). Upgrade path: resolve the graphicspath precedence and reuse this here too.

enum ImageProxyCache {
    /// Downscale `image` to `maxDim` px (longest side) if it's a large raster. Proxy keeps the
    /// original basename and is cached by (path,size,mtime). Returns the proxy URL, or nil if the
    /// original is small enough / not a downscalable raster.
    @discardableResult
    static func proxy(for image: URL, maxDim: Int = 1600, cacheDir: URL,
                      minBytes: Int = 2_000_000) -> URL? {
        let ext = image.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tiff", "tif"].contains(ext) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: image.path),
              let size = attrs[.size] as? Int, size >= minBytes else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(image.path)|\(size)|\(mtime)|\(maxDim)"
        let bucket = cacheDir.appending(path: stableHash(key))
        let out = bucket.appending(path: image.lastPathComponent)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try? FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sips")
        p.arguments = ["-Z", "\(maxDim)", image.path, "--out", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return p.terminationStatus == 0 ? out : nil
    }
}

#endif

// MARK: - Engine → latexmk flag (available on all platforms)

extension TexEngine {
    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex:  return "-pdfxe"
        case .lualatex: return "-pdflua"
        }
    }
}
