import Foundation

// MARK: - Profiles & results

/// Preview and export profiles. Only `finalCompile` is allowed to publish beside the source.
enum CompileProfile: Equatable {
    case fastPreview    // draft images, fewest reruns — lowest edit-to-preview latency
    case imagePreview   // screen-resolution image proxies, single pass, never exported
    case finalCompile   // full-res images, rerun-until-stable, biber — correct numbering
}

struct CompileResult: Sendable {
    let pdfURL: URL
    let synctexURL: URL?
    let recorderURL: URL?
    /// The exact source path recorded by SyncTeX (often a private build copy).
    let compiledTexURL: URL?
    let usedWarmEngine: Bool
    let log: String

    init(pdfURL: URL, synctexURL: URL?, recorderURL: URL? = nil,
         compiledTexURL: URL? = nil, usedWarmEngine: Bool = false, log: String) {
        self.pdfURL = pdfURL
        self.synctexURL = synctexURL
        self.recorderURL = recorderURL
        self.compiledTexURL = compiledTexURL
        self.usedWarmEngine = usedWarmEngine
        self.log = log
    }
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
        let fls = outDir.appending(path: base + ".fls")

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
        let flsURL = FileManager.default.fileExists(atPath: fls.path) ? fls : nil
        return CompileResult(pdfURL: pdf, synctexURL: synURL, recorderURL: flsURL,
                             compiledTexURL: texPath, log: r.output)
    }

    private func runOnce(texPath: URL, cwd: URL, outDir: URL, engine: TexEngine, profile: CompileProfile) async -> (status: Int32, output: String) {
        // -cd-: stay in `cwd` (relative \includegraphics/\input resolve there) while writing all
        // artifacts to -outdir. latexmk would otherwise chdir to the input file's (temp) dir.
        var args = [
            "latexmk",
            engine.latexmkFlag,
            "-synctex=1",
            "-recorder",
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

/// A deliberately single-pass backend for the image-enhanced live preview. Cross-reference and
/// bibliography stabilization remain the responsibility of Final Build; this pass only replaces
/// the already-visible draft with screen-resolution images.
struct ImagePreviewBackend: CompileBackend {
    func compile(texPath: URL, cwd: URL, outDir: URL, engine: TexEngine,
                 profile: CompileProfile) async throws -> CompileResult {
        precondition(profile == .imagePreview)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let args = [engine.rawValue, "-synctex=1", "-recorder", "-interaction=nonstopmode",
                    "-file-line-error", "-output-directory=" + outDir.path, texPath.path]
        let r = await Subprocess.run(args, cwd: cwd)
        let base = texPath.deletingPathExtension().lastPathComponent
        let pdf = outDir.appending(path: base + ".pdf")
        guard r.status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw CompilerError.buildFailed(r.output)
        }
        let syn = outDir.appending(path: base + ".synctex.gz")
        let fls = outDir.appending(path: base + ".fls")
        return CompileResult(
            pdfURL: pdf,
            synctexURL: FileManager.default.fileExists(atPath: syn.path) ? syn : nil,
            recorderURL: FileManager.default.fileExists(atPath: fls.path) ? fls : nil,
            compiledTexURL: texPath,
            log: r.output
        )
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
        p.arguments = [engine.rawValue, "-synctex=1", "-recorder", "-file-line-error",
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
        let fls = outDir.appending(path: base + ".fls")
        guard status == 0, FileManager.default.fileExists(atPath: pdf.path) else { return nil }
        let synURL = FileManager.default.fileExists(atPath: syn.path) ? syn : nil
        let flsURL = FileManager.default.fileExists(atPath: fls.path) ? fls : nil
        return CompileResult(pdfURL: pdf, synctexURL: synURL, recorderURL: flsURL,
                             compiledTexURL: buildTex, usedWarmEngine: true, log: sink.string())
    }

    /// Terminate the parked process (document close / app teardown / preamble change).
    func kill() {
        if let p = proc, p.isRunning {
            try? stdinHandle?.close()
            p.terminate()
            p.waitUntilExit()
        }
        outHandle?.readabilityHandler = nil
        proc = nil; stdinHandle = nil; outHandle = nil; sink = nil; armedKey = nil
    }
}

// ponytail: removed PrecompiledFormatBackend (pdflatex-only .fmt path) — dead since WarmEngine
// (tex-fast-recompile) covers all engines. Restore from git if a .fmt fast path is ever needed.

// MARK: - Image proxy cache (docs/03 §3.6) — downscale oversized rasters, cached by content.
//
// Live preview uses these proxies through a same-relative-path project mirror. Source text is never
// rewritten, so graphicspath precedence and extension omission remain TeX's responsibility.

enum ImageProxyCache {
    static let settingsVersion = 2

    struct Metadata: Equatable {
        let pixelWidth: Double
        let pixelHeight: Double
        let dpiWidth: Double
        let dpiHeight: Double
    }

    /// Downscale `image` to `maxDim` px (longest side) if it's a large raster. Proxy keeps the
    /// original basename and is cached by (path,size,mtime,settings). Returns the proxy URL, or nil if the
    /// original is small enough / not a downscalable raster.
    @discardableResult
    static func proxy(for image: URL, maxDim: Int = 1600, cacheDir: URL,
                      minBytes: Int = 2_000_000) -> URL? {
        let ext = image.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tiff", "tif"].contains(ext) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: image.path),
              let size = attrs[.size] as? Int else { return nil }
        let originalMetadata = metadata(for: image)
        let needsResize = originalMetadata.map {
            max($0.pixelWidth, $0.pixelHeight) > Double(maxDim)
        } ?? (size >= minBytes)
        guard needsResize else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "v\(settingsVersion)|\(image.standardizedFileURL.path)|\(size)|\(mtime)|\(maxDim)|\(minBytes)"
        let bucket = cacheDir.appending(path: stableHash(key))
        let out = bucket.appending(path: image.lastPathComponent)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try? FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)

        let temporary = bucket.appending(path: ".proxy-\(UUID().uuidString)." + ext)

        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sips")
        p.arguments = ["-Z", "\(maxDim)", image.path, "--out", temporary.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }

        // sips keeps the original DPI while reducing pixels, which would shrink an image inserted
        // without width/height options. Scale DPI by the same pixel ratio so its TeX natural size
        // remains unchanged. Explicit-width images are unaffected, and aspect ratio is preserved by -Z.
        if let before = originalMetadata, let after = metadata(for: temporary),
           before.pixelWidth > 0, before.pixelHeight > 0 {
            let sx = after.pixelWidth / before.pixelWidth
            let sy = after.pixelHeight / before.pixelHeight
            setDPI(of: temporary, width: before.dpiWidth * sx, height: before.dpiHeight * sy)
        }

        do {
            // Multiple generations can request the same cache key concurrently. First writer wins;
            // every later writer simply discards its equivalent temporary proxy.
            if FileManager.default.fileExists(atPath: out.path) {
                try? FileManager.default.removeItem(at: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: out)
            }
            return out
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return FileManager.default.fileExists(atPath: out.path) ? out : nil
        }
    }

    static func metadata(for image: URL) -> Metadata? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(filePath: "/usr/bin/sips")
        p.arguments = ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "dpiWidth", "-g", "dpiHeight", image.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let output = String(decoding: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        func value(_ name: String) -> Double? {
            let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: name) + ":\\s*([0-9.]+)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else { return nil }
            return Double(output[range])
        }
        guard let w = value("pixelWidth"), let h = value("pixelHeight") else { return nil }
        return Metadata(pixelWidth: w, pixelHeight: h,
                        dpiWidth: value("dpiWidth") ?? 72,
                        dpiHeight: value("dpiHeight") ?? 72)
    }

    private static func setDPI(of image: URL, width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sips")
        p.arguments = ["--setProperty", "dpiWidth", String(format: "%.6f", width),
                       "--setProperty", "dpiHeight", String(format: "%.6f", height), image.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Isolated live-preview pipelines

/// Copies completed compiler outputs into a directory that no compiler process will ever mutate.
/// PDFKit only receives URLs returned by this function.
enum CompilePublication {
    static func publish(_ raw: CompileResult, into stageDir: URL,
                        fallbackSync: CompileResult? = nil) throws -> CompileResult {
        let fm = FileManager.default
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let temporary = stageDir.appending(path: ".result-\(UUID().uuidString)", directoryHint: .isDirectory)
        let published = stageDir.appending(path: "result", directoryHint: .isDirectory)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)

        let base = raw.pdfURL.deletingPathExtension().lastPathComponent
        let pdf = temporary.appending(path: base + ".pdf")
        try fm.copyItem(at: raw.pdfURL, to: pdf)

        var synOut: URL?
        var compiledTex = raw.compiledTexURL
        if let syn = raw.synctexURL ?? fallbackSync?.synctexURL {
            let out = temporary.appending(path: base + ".synctex.gz")
            try fm.copyItem(at: syn, to: out)
            synOut = out
            if raw.synctexURL == nil { compiledTex = fallbackSync?.compiledTexURL }
        }
        var flsOut: URL?
        if let fls = raw.recorderURL {
            let out = temporary.appending(path: base + ".fls")
            try fm.copyItem(at: fls, to: out)
            flsOut = out
        }
        if fm.fileExists(atPath: published.path) { try fm.removeItem(at: published) }
        try fm.moveItem(at: temporary, to: published)
        return CompileResult(
            pdfURL: published.appending(path: pdf.lastPathComponent),
            synctexURL: synOut.map { published.appending(path: $0.lastPathComponent) },
            recorderURL: flsOut.map { published.appending(path: $0.lastPathComponent) },
            compiledTexURL: compiledTex,
            usedWarmEngine: raw.usedWarmEngine,
            log: raw.log
        )
    }
}

private func atomicWrite(_ data: Data, to destination: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = destination.deletingLastPathComponent()
        .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary)
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.moveItem(at: temporary, to: destination)
}

/// The only owner of draft scratch and WarmEngine. Actor isolation prevents rapid saves from
/// writing the stable warm source/output concurrently; generation publication remains isolated.
actor DraftPreviewCompiler {
    private let warm = WarmEngine()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func compile(source: String, sourceURL: URL, engine: TexEngine, warmRoot: URL,
                 stageDir: URL, resources: String, useWarm: Bool) async throws -> CompileResult {
        await acquire()
        do {
            let result = try await performCompile(source: source, sourceURL: sourceURL, engine: engine,
                                                  warmRoot: warmRoot, stageDir: stageDir,
                                                  resources: resources, useWarm: useWarm)
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func performCompile(source: String, sourceURL: URL, engine: TexEngine, warmRoot: URL,
                                stageDir: URL, resources: String, useWarm: Bool) async throws -> CompileResult {
        let fm = FileManager.default
        try fm.createDirectory(at: warmRoot, withIntermediateDirectories: true)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let buildTex = warmRoot.appending(path: base + "-itexwarm.tex")
        try atomicWrite(Data(source.utf8), to: buildTex)

        let styOK = !resources.isEmpty && fm.fileExists(atPath: resources + "/fastrecompile.sty")
        let canWarm = useWarm && styOK
        let marker = source.range(of: "\\begin{document}")
        let preamble = marker.map { String(source[..<$0.lowerBound]) } ?? source
        let preambleHash = canWarm ? stableHash(preamble) : ""

        if canWarm,
           let raw = await warm.tryCompile(buildTex: buildTex, engine: engine,
                                           preambleHash: preambleHash, outDir: warmRoot) {
            let published = try CompilePublication.publish(raw, into: stageDir)
            await warm.arm(buildTex: buildTex, engine: engine, preambleHash: preambleHash,
                           cwd: sourceURL.deletingLastPathComponent(), outDir: warmRoot,
                           resources: resources)
            return published
        }

        await warm.kill()
        let raw = try await LatexmkBackend().compile(
            texPath: buildTex, cwd: sourceURL.deletingLastPathComponent(), outDir: warmRoot,
            engine: engine, profile: .fastPreview
        )
        let published = try CompilePublication.publish(raw, into: stageDir)
        if canWarm {
            await warm.arm(buildTex: buildTex, engine: engine, preambleHash: preambleHash,
                           cwd: sourceURL.deletingLastPathComponent(), outDir: warmRoot,
                           resources: resources)
        }
        return published
    }

    func shutdown() async {
        await acquire()
        await warm.kill()
        release()
    }

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct ImagePreviewPlan: Sendable {
    let projectRoot: URL
    let mainRelativePath: String
    let imageFiles: [URL]
    let hasGraphics: Bool
    let requiresOriginalTreeFallback: Bool
}

struct ImagePreviewBuild: Sendable {
    let result: CompileResult
    let proxyCount: Int
    let originalFallbackCount: Int
    let usedOriginalTreeFallback: Bool
}

/// Plans a mirror from recorder dependencies. It never rewrites `\includegraphics`: TeX sees the
/// same relative paths/names in a symlink tree, with eligible raster links replaced by proxies.
enum ImagePreviewProject {
    static let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff"]
    static let graphicExtensions: Set<String> = rasterExtensions.union(["pdf", "eps"])
    private static let sourceExtensions: Set<String> = ["tex", "sty", "cls"]

    static func plan(source: String, sourceURL: URL, recorderURL: URL?) -> ImagePreviewPlan {
        let root = sourceURL.deletingLastPathComponent().standardizedFileURL
        var dependencies = recorderURL.map { recorderInputs($0, relativeTo: root) } ?? []
        dependencies = dependencies.map(\.standardizedFileURL)
        let projectDependencies = dependencies.filter { isInside($0, root: root) }
        var images = projectDependencies.filter { graphicExtensions.contains($0.pathExtension.lowercased()) }

        var sourceHasCommand = containsGraphicsCommand(source)
        if !sourceHasCommand {
            for dependency in projectDependencies where sourceExtensions.contains(dependency.pathExtension.lowercased()) {
                if let text = try? String(contentsOf: dependency, encoding: .utf8),
                   containsGraphicsCommand(text) {
                    sourceHasCommand = true
                    break
                }
            }
        }

        // Some draft drivers record only TeX inputs, not raster files. In that case scan the
        // project for candidate assets, while still leaving path resolution entirely to TeX.
        if images.isEmpty, sourceHasCommand {
            images = projectGraphics(root: root)
        }
        images = Array(Set(images.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        let externalGraphic = dependencies.contains {
            let path = $0.standardizedFileURL.path
            let systemAsset = path.hasPrefix("/usr/") || path.hasPrefix("/System/")
                || path.hasPrefix("/Library/TeX/")
            return graphicExtensions.contains($0.pathExtension.lowercased())
                && !isInside($0, root: root) && !systemAsset
        }
        let relative = relativePath(sourceURL.standardizedFileURL, under: root) ?? sourceURL.lastPathComponent
        return ImagePreviewPlan(projectRoot: root, mainRelativePath: relative, imageFiles: images,
                                hasGraphics: sourceHasCommand || !images.isEmpty,
                                requiresOriginalTreeFallback: externalGraphic)
    }

    static func compile(plan: ImagePreviewPlan, source: String, sourceURL: URL,
                        engine: TexEngine, stageDir: URL, cacheDir: URL,
                        draftResult: CompileResult) async throws -> ImagePreviewBuild {
        let fm = FileManager.default
        let work = stageDir.appending(path: "work", directoryHint: .isDirectory)
        let mirror = stageDir.appending(path: "project", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        var proxyCount = 0
        var fallbackCount = 0
        let texPath: URL
        let cwd: URL
        var originalFallback = plan.requiresOriginalTreeFallback

        if !originalFallback {
            do {
                try createSymlinkMirror(root: plan.projectRoot, at: mirror)
                let main = mirror.appending(path: plan.mainRelativePath)
                if fm.fileExists(atPath: main.path) { try fm.removeItem(at: main) }
                try atomicWrite(Data(source.utf8), to: main)
                for image in plan.imageFiles where isInside(image, root: plan.projectRoot) {
                    guard let relative = relativePath(image, under: plan.projectRoot) else { continue }
                    let mirrored = mirror.appending(path: relative)
                    if let proxy = ImageProxyCache.proxy(for: image, cacheDir: cacheDir) {
                        if fm.fileExists(atPath: mirrored.path) { try fm.removeItem(at: mirrored) }
                        try fm.createSymbolicLink(at: mirrored, withDestinationURL: proxy)
                        proxyCount += 1
                    } else if rasterExtensions.contains(image.pathExtension.lowercased()) {
                        // Ineligible small rasters and failed conversions both safely use originals.
                        fallbackCount += 1
                    }
                }
                texPath = main
                cwd = mirror
            } catch {
                originalFallback = true
                try? fm.removeItem(at: mirror)
                let fallbackSource = stageDir.appending(path: "source", directoryHint: .isDirectory)
                    .appending(path: sourceURL.lastPathComponent)
                try atomicWrite(Data(source.utf8), to: fallbackSource)
                texPath = fallbackSource
                cwd = plan.projectRoot
            }
        } else {
            let fallbackSource = stageDir.appending(path: "source", directoryHint: .isDirectory)
                .appending(path: sourceURL.lastPathComponent)
            try atomicWrite(Data(source.utf8), to: fallbackSource)
            texPath = fallbackSource
            cwd = plan.projectRoot
        }

        let raw = try await ImagePreviewBackend().compile(texPath: texPath, cwd: cwd, outDir: work,
                                                          engine: engine, profile: .imagePreview)
        let result = try CompilePublication.publish(raw, into: stageDir, fallbackSync: draftResult)
        return ImagePreviewBuild(result: result, proxyCount: proxyCount,
                                 originalFallbackCount: fallbackCount,
                                 usedOriginalTreeFallback: originalFallback)
    }

    private static func recorderInputs(_ recorder: URL, relativeTo root: URL) -> [URL] {
        guard let text = try? String(contentsOf: recorder, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("INPUT ") else { return nil }
            var path = String(line.dropFirst(6))
            if path.hasPrefix("\"") && path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
            return path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
        }
    }

    /// TeX-aware enough for scheduling only: ignore unescaped `%` comments without attempting to
    /// parse or rewrite includegraphics arguments. TeX remains the sole path resolver.
    private static func containsGraphicsCommand(_ source: String) -> Bool {
        for line in source.components(separatedBy: .newlines) {
            var active = ""
            var backslashes = 0
            for character in line {
                if character == "%", backslashes.isMultiple(of: 2) { break }
                active.append(character)
                if character == "\\" { backslashes += 1 } else { backslashes = 0 }
            }
            if active.contains("\\includegraphics") { return true }
        }
        return false
    }

    private static func projectGraphics(root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in e {
            if graphicExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result
    }

    private static func createSymlinkMirror(root: URL, at mirror: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: mirror.path) { try fm.removeItem(at: mirror) }
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let source as URL in e {
            guard let relative = relativePath(source, under: root) else { continue }
            let destination = mirror.appending(path: relative)
            let values = try source.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: destination, withDestinationURL: source)
            }
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        relativePath(url, under: root) != nil
    }

    private static func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
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
