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
    /// `texPath` is already written to disk. `cwd` is where relative \includegraphics/\input
    /// resolve (the user's source dir); `outDir` receives every build artifact (kept out of the
    /// source folder). They may be the same dir for backends that don't separate them.
    func compile(texPath: URL, cwd: URL, outDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult
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
final class OutputSink: @unchecked Sendable {   // NSLock-guarded → safe across the drain threads
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
    func compile(texPath: URL, cwd: URL, outDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult {
        let base = texPath.deletingPathExtension().lastPathComponent
        let pdf = outDir.appending(path: base + ".pdf")
        let syn = outDir.appending(path: base + ".synctex.gz")

        var r = await runOnce(texPath: texPath, cwd: cwd, outDir: outDir, engine: engine, profile: profile)
        // latexmk sticky-error state: once a run errors it records it in <base>.fdb_latexmk and then
        // REFUSES to rebuild until the source changes ("gave an error in previous invocation"),
        // exiting nonzero forever — a one-off interruption (or a warm-engine jobname clash) wedges
        // the preview permanently. Clear its db + the corrupt outputs and retry once.
        if r.status != 0, r.output.contains("previous invocation of latexmk") {
            for ext in ["fdb_latexmk", "pdf", "xdv"] {
                try? FileManager.default.removeItem(at: outDir.appending(path: base + "." + ext))
            }
            r = await runOnce(texPath: texPath, cwd: cwd, outDir: outDir, engine: engine, profile: profile)
        }
        guard r.status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw CompilerError.buildFailed(r.output)
        }
        let synURL = FileManager.default.fileExists(atPath: syn.path) ? syn : nil
        return CompileResult(pdfURL: pdf, synctexURL: synURL, log: r.output)
    }

    private func runOnce(texPath: URL, cwd: URL, outDir: URL, engine: TexEngine, profile: CompileProfile) async -> (status: Int32, output: String) {
        // -cd-: stay in `cwd` (relative \includegraphics/\input resolve there) while writing all
        // artifacts to -outdir. latexmk would otherwise chdir to the input file's (temp) dir.
        var args = [
            "latexmk",
            engine.latexmkFlag,
            "-synctex=1",
            "-interaction=nonstopmode",
            "-file-line-error",
            "-cd-",
            "-outdir=" + outDir.path,
        ]
        if profile == .fastPreview {
            // Skip image decode/embed without touching the user's source (docs/03 §3.4, verified).
            args.append("-usepretex=\\PassOptionsToPackage{draft}{graphicx}")
        }
        args.append(texPath.path)
        return await Subprocess.run(args, cwd: cwd)
    }
}

// MARK: - Warm pre-started engine (docs/03 §3.3) — the all-engine fast-preview path
//
// The .fmt backend below is pdflatex-only by nature: XeTeX hard-refuses `\dump` once a native
// font is live ("Can't \dump a format with native fonts"), and LuaTeX can't serialize luaotfload
// Lua state. So fontspec / Korean (kotex/xeCJK) / lualatex docs cannot get a warm .fmt at all.
//
// This actor reuses the tex-fast-recompile technique instead (vendored Resources/fastrecompile.sty,
// LPPL 1.3c): keep ONE live engine process parked at \begin{document}, blocked on a terminal read,
// with the whole preamble + OpenType fonts already loaded in RAM. On the next save we write the
// build-copy path to its stdin; the .sty re-\inputs that file, gobbles the preamble lines, and
// typesets only the body on top of the warm state. Fonts live in the process — never serialized —
// so this works identically for pdflatex / xelatex / lualatex. It also emits real SyncTeX every
// recompile (unlike the .fmt path, which returns nil), because it \inputs the real build copy.
//
// errorstopmode is mandatory: the .sty's terminal \read returns EOF under -interaction=nonstopmode,
// so we pass NO -interaction flag and close stdin after feeding (a body error then EOF-exits instead
// of hanging). Single-pass → cross-refs can be one compile stale; ⌘B finalCompile (latexmk
// rerun+biber) stays the correctness backstop. Each warm process serves exactly one compile, then
// is killed and a fresh one is armed for the next edit (preamble pass amortized into idle time).
actor WarmEngine {
    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var outHandle: FileHandle?
    private var sink: OutputSink?
    private var armedKey: String?

    private func key(_ engine: TexEngine, _ preambleHash: String, _ tex: URL) -> String {
        "\(engine.rawValue)|\(preambleHash)|\(tex.path)"
    }

    /// Spawn a fresh engine that loads the preamble of `buildTex` and parks at \begin{document}.
    /// Kills any previously parked process first. No-op result on launch failure (warm unavailable).
    func arm(buildTex: URL, engine: TexEngine, preambleHash: String, cwd: URL, outDir: URL, resources: String) {
        kill()
        let job = buildTex.deletingPathExtension().lastPathComponent
        // Inject graphicx draft BEFORE the preamble loads → images become labelled boxes, skipping
        // decode/embed (docs/03 §3.4). This is the warm equivalent of latexmk's -usepretex draft;
        // warm only runs for fastPreview, so it always applies. \PassOptionsToPackage is a no-op
        // (harmless "unused option" note) if the doc never loads graphicx.
        // ponytail: \input{abspath} via braces tolerates spaces; a path with %, \, { } would break
        // the wrapper → the parked engine errors → tryCompile gets no PDF → latexmk fallback. Fine.
        let wrapper = #"\PassOptionsToPackage{draft}{graphicx}\RequirePackage{fastrecompile}\fastrecompilecheckversion{0.5.0}\fastrecompilesetimplicitpreamble\input{"# + buildTex.path + "}"

        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.currentDirectoryURL = cwd   // relative graphics/input resolve in the source dir
        // No -interaction flag: errorstopmode is required for the .sty's terminal \read.
        p.arguments = [engine.rawValue, "-synctex=1", "-file-line-error",
                       "-jobname=" + job, "-output-directory=" + outDir.path, wrapper]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Subprocess.texPATH + ":" + (env["PATH"] ?? "")
        env["TEXINPUTS"] = resources + ":" + (env["TEXINPUTS"] ?? "")   // find vendored fastrecompile.sty
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        let out = outPipe.fileHandleForReading
        let sink = OutputSink()
        // Drain the preamble pass's output while parked, so a chatty preamble can't fill the pipe.
        out.readabilityHandler = { fh in let d = fh.availableData; if !d.isEmpty { sink.append(d) } }

        do { try p.run() } catch { return }   // warm unavailable; armedKey stays nil → caller uses latexmk
        proc = p
        stdinHandle = inPipe.fileHandleForWriting
        outHandle = out
        self.sink = sink
        armedKey = key(engine, preambleHash, buildTex)
    }

    /// Feed the body to the parked engine and await the PDF. Returns nil (→ caller falls back to
    /// latexmk) if nothing is armed, the preamble/engine changed, the process died, or no PDF resulted.
    func tryCompile(buildTex: URL, engine: TexEngine, preambleHash: String, outDir: URL) async -> CompileResult? {
        guard let p = proc, let sin = stdinHandle, let out = outHandle, let sink = sink,
              p.isRunning, armedKey == key(engine, preambleHash, buildTex)
        else { return nil }
        // Consume: this parked process serves exactly one compile.
        proc = nil; stdinHandle = nil; outHandle = nil; self.sink = nil; armedKey = nil

        let path = buildTex.path
        let status: Int32 = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                do { try sin.write(contentsOf: Data((path + "\n").utf8)) } catch {}
                try? sin.close()                 // close → a body error hits EOF and exits, no hang
                p.waitUntilExit()                // returns immediately if already exited (no handler race)
                out.readabilityHandler = nil
                if let d = try? out.readToEnd(), !d.isEmpty { sink.append(d) }
                cont.resume(returning: p.terminationStatus)
            }
        }

        let base = buildTex.deletingPathExtension().lastPathComponent
        let pdf = outDir.appending(path: base + ".pdf")
        let syn = outDir.appending(path: base + ".synctex.gz")
        guard status == 0, FileManager.default.fileExists(atPath: pdf.path) else { return nil }
        let synURL = FileManager.default.fileExists(atPath: syn.path) ? syn : nil
        return CompileResult(pdfURL: pdf, synctexURL: synURL, log: sink.string())
    }

    /// Terminate the parked process (document close / app teardown / preamble change).
    func kill() {
        if let p = proc, p.isRunning { try? stdinHandle?.close(); p.terminate() }
        outHandle?.readabilityHandler = nil
        proc = nil; stdinHandle = nil; outHandle = nil; sink = nil; armedKey = nil
    }
}

// ponytail: removed PrecompiledFormatBackend (pdflatex-only .fmt path) — dead since WarmEngine
// (tex-fast-recompile) covers all engines. Restore from git if a .fmt fast path is ever needed.

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
