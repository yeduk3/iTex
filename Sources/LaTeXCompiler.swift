import Foundation
import Observation
import CoreGraphics

enum TexEngine: String, CaseIterable, Identifiable {
    case xelatex, pdflatex, lualatex
    var id: String { rawValue }
    var label: String { rawValue }
}

// SyncTeX cross-view state (editor ↔ preview). Token fields dedupe so SwiftUI
// `updateNSView` reacts once per request without mutating state during view updates.
struct ForwardHighlight: Equatable {
    let page: Int            // 1-based
    let rects: [CGRect]      // PDFKit page coords
    let token: Int
}
struct SelectLineRequest: Equatable {
    let line: Int            // 1-based
    let token: Int
}

@MainActor
@Observable
final class LaTeXCompiler {
    var pdfURL: URL?
    var synctexURL: URL?
    var isCompiling = false
    var errorMessage: String?
    var errorMessages: [Int: String] = [:]   // 1-based source line → error text, from last failed build
    var compilationID = 0
    // Auto-detected from the document each compile (detectEngine) — no engine picker.
    // All engines share the warm pre-started fast path; fontspec/CJK docs auto-route to xelatex.
    var engine: TexEngine = .pdflatex
    var fileURL: URL?

    var useWarmEngine = true

    // SyncTeX state
    var cursorLine = 1
    var forwardHighlight: ForwardHighlight?
    var selectLineRequest: SelectLineRequest?      // ⌘-click inverse search → select+scroll the line
    var scrollToLineRequest: SelectLineRequest?    // scroll-sync inverse → center the line (no selection)
    private var syncToken = 0

    // Scroll-sync mode: editor viewport center ↔ PDF viewport center (bidirectional).
    var scrollSyncEnabled = false
    private var syncCooldownUntil: CFAbsoluteTime = 0
    /// Mark a short window after a programmatic sync-scroll so the echo doesn't loop back.
    func beginSyncCooldown() { syncCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.35 }
    var inSyncCooldown: Bool { CFAbsoluteTimeGetCurrent() < syncCooldownUntil }

    private var debounceTask: Task<Void, Never>?
    private let workDir: URL
    /// The .tex actually handed to the engine. With a saved doc this is a build copy
    /// (sibling of fileURL), so SyncTeX must use it, not fileURL.
    private var compiledTexURL: URL?
#if os(macOS)
    /// Warm pre-started engine for fast preview (all engines, docs/03 §3.3).
    private let warmEngine = WarmEngine()
#endif

    init() {
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "itex-build", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// Pick the TeX engine from the document — the engine is a compatibility choice the
    /// document forces, not a user/perf setting. Order: magic comment override → content
    /// heuristics → pdflatex default. All engines get the warm fast path (docs/03 §3.3).
    static func detectEngine(_ source: String) -> TexEngine {
        // 1. TeXShop/VSCode magic comment: `% !TEX program = xelatex` (also TS-program).
        if let prog = magicProgram(source) {
            switch prog {
            case "xelatex", "xetex":            return .xelatex
            case "lualatex", "luatex":          return .lualatex
            case "pdflatex", "pdftex", "latex": return .pdflatex
            default: break
            }
        }
        // 2. Content heuristics. lua-only features first, then xetex/fontspec/CJK family.
        if ["\\directlua", "luacode", "luatexja"].contains(where: source.contains) {
            return .lualatex
        }
        let xetexMarkers = ["fontspec", "unicode-math", "\\setmainfont", "\\setsansfont",
                            "\\setmonofont", "xeCJK", "kotex", "ctex", "xetexko", "polyglossia"]
        if xetexMarkers.contains(where: source.contains) { return .xelatex }
        // 3. Default: pdflatex.
        return .pdflatex
    }

    /// First `% !TEX [TS-]program = <engine>` value, lowercased; nil if absent.
    private static func magicProgram(_ source: String) -> String? {
        let pattern = #"(?im)^\s*%\s*!TE?X\s+(?:TS-)?program\s*=\s*([A-Za-z]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let r = Range(m.range(at: 1), in: source)
        else { return nil }
        return source[r].lowercased()
    }

    /// Source before `\begin{document}` — the warm key is hashed over this, so a body-only edit
    /// keeps the parked engine valid while a preamble edit invalidates it (forces a fresh pass).
    static func preamble(of source: String) -> String {
        if let r = source.range(of: "\\begin{document}") { return String(source[..<r.lowerBound]) }
        return source
    }

    /// Live edit loop → fast-preview compile after idle.
    func scheduleCompile(source: String) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            await self.compile(source: source, profile: .fastPreview)
        }
    }

    func compile(source: String, profile: CompileProfile = .finalCompile) async {
        engine = Self.detectEngine(source)   // doc decides the engine, not the user
        isCompiling = true
        errorMessage = nil
        defer { isCompiling = false }

        do {
            let result = try await buildPDF(source: source, profile: profile)
            pdfURL = result.pdfURL
            // Warm + latexmk paths both emit SyncTeX now; keep the last good one defensively.
            if let syn = result.synctexURL { synctexURL = syn }
            errorMessages = [:]
            compilationID += 1
#if os(macOS)
            // Mirror the full build PDF next to the .tex (the user-facing output). Only on a real
            // build — fast-preview saves draft images, so they stay in temp.
            if profile == .finalCompile { exportPDF(from: result.pdfURL) }
#endif
        } catch {
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            errorMessages = (error as? CompilerError).map(Self.errorMessages(from:)) ?? [:]
        }
    }

    /// Map source line → error text from a TeX build log. Primary: `-file-line-error`
    /// form `<path>.tex:12: message`. Fallback: `! message` paired with `l.12`.
    static func errorMessages(from error: CompilerError) -> [Int: String] {
        guard case .buildFailed(let log) = error else { return [:] }
        var out: [Int: String] = [:]
        let nsLog = log as NSString
        let full = NSRange(location: 0, length: nsLog.length)

        let fileLine = try! NSRegularExpression(pattern: #"(?m)\.tex:(\d+):\s*(.+)$"#)
        for m in fileLine.matches(in: log, range: full) {
            guard let n = Int(nsLog.substring(with: m.range(at: 1))) else { continue }
            let msg = nsLog.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            out[n] = out[n].map { $0 + "\n" + msg } ?? msg
        }
        if out.isEmpty {   // engines without -file-line-error
            let bang = try! NSRegularExpression(pattern: #"(?m)^! (.+)$"#)
            let lLine = try! NSRegularExpression(pattern: #"(?m)^l\.(\d+)\b"#)
            if let lm = lLine.firstMatch(in: log, range: full),
               let n = Int(nsLog.substring(with: lm.range(at: 1))) {
                let msg = bang.firstMatch(in: log, range: full).map { nsLog.substring(with: $0.range(at: 1)) } ?? "LaTeX error"
                out[n] = msg
            }
        }
        return out
    }

    /// Force a clean rebuild: discard the document's cached build artifacts (latexmk state, aux,
    /// stale PDF), then run a full compile from scratch.
    func cleanBuild(source: String) async {
#if os(macOS)
        await warmEngine.kill()
        if let fileURL { try? FileManager.default.removeItem(at: buildDir(for: fileURL)) }
#endif
        await compile(source: source, profile: .finalCompile)
    }

#if os(macOS)
    /// Per-document scratch dir in the app's temp area — every build artifact lives here, never in
    /// the user's source folder. Stable per file path so latexmk's incremental state persists.
    private func buildDir(for fileURL: URL) -> URL {
        workDir.appending(path: stableHash(fileURL.path), directoryHint: .isDirectory)
    }

    /// Copy the freshly built PDF next to the source .tex as "<base>.pdf" — the only artifact that
    /// lands in the user's folder. Writes a sibling of the .tex, never the .tex itself (no mtime
    /// conflict). ponytail: copies on the main actor; a multi-MB PDF is a brief hitch, move to a
    /// detached task if it ever bites.
    private func exportPDF(from built: URL) {
        guard let fileURL else { return }
        let dest = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: built, to: dest)
    }
#endif

    private func buildPDF(source: String, profile: CompileProfile) async throws -> CompileResult {
#if os(macOS)
        // All build artifacts (build copy + outputs) live in a per-document temp dir, never in the
        // user's source folder. `cwd` stays the source dir so relative \includegraphics/\input
        // resolve; the user's file is NEVER written out-of-band (its own save is the only writer —
        // touching it would bump mtime and trip NSDocument's "modified externally" conflict).
        // ponytail: jobname is "<base>-itexbuild"; a doc that hardcodes \jobname would notice.
        let texPath: URL, cwd: URL, outDir: URL
        if let fileURL {
            let base = fileURL.deletingPathExtension().lastPathComponent
            cwd = fileURL.deletingLastPathComponent()
            outDir = buildDir(for: fileURL)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let buildTex = outDir.appending(path: "\(base)-itexbuild.tex")
            try Data(source.utf8).write(to: buildTex)
            texPath = buildTex
            compiledTexURL = buildTex
        } else {
            let tex = workDir.appending(path: "document.tex")
            try Data(source.utf8).write(to: tex)
            texPath = tex
            cwd = workDir
            outDir = workDir
        }

        // Fast preview → warm pre-started engine for ALL engines (docs/03 §3.3): pdflatex,
        // xelatex (fontspec/kotex/xeCJK), lualatex all reuse the in-RAM preamble + fonts.
        // Needs a saved doc (stable build-copy path) and the vendored fastrecompile.sty.
        let resources = Bundle.main.resourceURL?.path ?? ""
        let styOK = !resources.isEmpty
            && FileManager.default.fileExists(atPath: resources + "/fastrecompile.sty")
        let canWarm = useWarmEngine && fileURL != nil && styOK
        let preambleHash = canWarm ? stableHash(Self.preamble(of: source)) : ""

        if canWarm, profile == .fastPreview,
           let r = await warmEngine.tryCompile(buildTex: texPath, engine: engine,
                                               preambleHash: preambleHash, outDir: outDir) {
            // Arm a fresh process so the next save is warm too (preamble pass runs during idle).
            // ponytail: re-arms every fast preview — a wasted spawn during rapid typing, but it's
            // background and each save still feeds the previously-warmed engine. Optimize if it bites.
            await warmEngine.arm(buildTex: texPath, engine: engine, preambleHash: preambleHash,
                                 cwd: cwd, outDir: outDir, resources: resources)
            return r
        }

        // latexmk: finalCompile (rerun-until-stable + biber, the correctness backstop), a warm miss,
        // or an unsaved doc. Kill any parked warm engine first — it shares jobname+outdir with
        // latexmk, so a concurrent run corrupts <base>.xdv/.aux and wedges latexmk's error state.
        // arm() below re-arms a fresh one for the next fast preview.
        await warmEngine.kill()
        let r = try await LatexmkBackend().compile(texPath: texPath, cwd: cwd, outDir: outDir, engine: engine, profile: profile)
        if canWarm {
            await warmEngine.arm(buildTex: texPath, engine: engine, preambleHash: preambleHash,
                                 cwd: cwd, outDir: outDir, resources: resources)
        }
        return r
#elseif ITEX_TECTONIC
        // iOS: in-process Tectonic (no subprocess). Requires the FFI lib + a shipped local bundle.
        let tex = workDir.appending(path: "document.tex")
        try Data(source.utf8).write(to: tex)
        return try await TectonicBackend().compile(texPath: tex, cwd: workDir, outDir: workDir, engine: engine, profile: profile)
#else
        // iOS without the Tectonic lib linked yet.
        throw CompilerError.platformUnsupported
#endif
    }

    // MARK: - SyncTeX (docs/04 §4.3)

#if os(macOS)
    /// Forward search: locate the PDF region for an editor line (defaults to the cursor line).
    func forwardSearch(line: Int? = nil) async {
        guard let pdfURL, let texFile = compiledTexURL ?? fileURL else { return }
        let heights = PDFPageHeights(url: pdfURL)
        let results = await SyncTeXService.forward(
            line: line ?? cursorLine, texFile: texFile, pdf: pdfURL,
            pageHeight: { heights.height(page: $0) })
        guard let page = results.first?.page else { return }
        syncToken += 1
        forwardHighlight = ForwardHighlight(page: page, rects: results.filter { $0.page == page }.map(\.rect), token: syncToken)
    }

    /// Scroll-sync: a PDF viewport-center point → the matching source line, to center in the editor.
    func syncPDFToEditor(page: Int, point: CGPoint, pageHeight: CGFloat) async {
        guard let pdfURL else { return }
        guard let hit = await SyncTeXService.inverse(page: page, point: point, pageHeight: pageHeight, pdf: pdfURL)
        else { return }
        syncToken += 1
        scrollToLineRequest = SelectLineRequest(line: hit.line, token: syncToken)
    }

    /// Inverse search: a PDF click → move the editor selection to that source line.
    func inverseSearch(page: Int, point: CGPoint, pageHeight: CGFloat) async {
        guard let pdfURL else { return }
        guard let hit = await SyncTeXService.inverse(page: page, point: point, pageHeight: pageHeight, pdf: pdfURL)
        else { return }
        syncToken += 1
        selectLineRequest = SelectLineRequest(line: hit.line, token: syncToken)
    }

    /// Terminate the parked warm engine (call on document close so it doesn't outlive the window).
    func shutdownWarm() async { await warmEngine.kill() }
#endif
}

enum CompilerError: LocalizedError {
    case buildFailed(String)
    case platformUnsupported

    var errorDescription: String? { displayMessage }

    var displayMessage: String {
        switch self {
        case .buildFailed(let log):
            let errorLines = log.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("!") || $0.contains("Error:") || $0.contains(".tex:") }
            return errorLines.isEmpty ? log : errorLines.prefix(12).joined(separator: "\n")
        case .platformUnsupported:
            return "LaTeX compilation on iOS requires the bundled Tectonic engine (not yet linked)."
        }
    }
}
