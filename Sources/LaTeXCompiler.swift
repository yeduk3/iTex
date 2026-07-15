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

enum PreviewState: Equatable {
    case idle
    case buildingDraft
    case loadingImages
    case ready
    case failed
}

@MainActor
@Observable
final class LaTeXCompiler {
    var pdfURL: URL?
    var synctexURL: URL?
    var previewState: PreviewState = .idle
    var isFinalBuilding = false
    var isCompiling: Bool { previewState == .buildingDraft || isFinalBuilding }
    var errorMessage: String?
    var imagePreviewError: String?
    var errorMessages: [Int: String] = [:]   // 1-based source line → error text, from last failed build
    var compilationID = 0
    private(set) var previewGeneration: UInt64 = 0
    private(set) var lastDraftDuration: TimeInterval?
    private(set) var lastImagePreviewDuration: TimeInterval?
    private(set) var lastImageProxyCount = 0
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
    private var imagePreviewTask: Task<Void, Never>?
    private let workDir: URL
    private let sessionID = UUID().uuidString
    /// The private .tex build copy actually handed to the engine, which SyncTeX must use.
    private var compiledTexURL: URL?
#if os(macOS)
    /// Owns the stable warm scratch. Completed PDFs are copied into generation-stage results.
    private let draftCompiler = DraftPreviewCompiler()
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

    /// Save/open uses the two-stage preview by default. Original images are reserved for the
    /// explicit `.finalCompile` toolbar action.
    func compile(source: String, profile: CompileProfile = .fastPreview) async {
        switch profile {
        case .fastPreview, .imagePreview:
            await compilePreview(source: source)
        case .finalCompile:
            await compileFinal(source: source)
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
        _ = nextGeneration()
        await draftCompiler.shutdown()
        if let fileURL {
            try? FileManager.default.removeItem(at: documentRoot(for: fileURL).appending(path: "warm"))
        }
#endif
        await compile(source: source, profile: .finalCompile)
    }

#if os(macOS)
    private func documentRoot(for fileURL: URL) -> URL {
        workDir.appending(path: stableHash(fileURL.standardizedFileURL.path), directoryHint: .isDirectory)
            .appending(path: sessionID, directoryHint: .isDirectory)
    }

    private func stageDir(for fileURL: URL, generation: UInt64, stage: String) -> URL {
        documentRoot(for: fileURL)
            .appending(path: String(generation), directoryHint: .isDirectory)
            .appending(path: stage, directoryHint: .isDirectory)
    }

    /// Copy the freshly built PDF next to the source .tex as "<base>.pdf" — the only artifact that
    /// lands in the user's folder. Writes a sibling of the .tex, never the .tex itself (no mtime
    /// conflict). ponytail: copies on the main actor; a multi-MB PDF is a brief hitch, move to a
    /// detached task if it ever bites.
    private func exportPDF(from built: URL) {
        guard let fileURL else { return }
        let dest = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        let temporary = dest.deletingLastPathComponent()
            .appending(path: ".\(dest.lastPathComponent).itex-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: built, to: temporary)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
#endif

    private func nextGeneration() -> UInt64 {
        previewGeneration &+= 1
        imagePreviewTask?.cancel()
        imagePreviewTask = nil
        return previewGeneration
    }

    private func publish(_ result: CompileResult) {
        pdfURL = result.pdfURL
        if let syn = result.synctexURL {
            synctexURL = syn
            compiledTexURL = result.compiledTexURL
        }
        compilationID &+= 1
    }

    private func compilePreview(source: String) async {
        let generation = nextGeneration()
        let selectedEngine = Self.detectEngine(source)
        engine = selectedEngine
        previewState = .buildingDraft
        errorMessage = nil
        imagePreviewError = nil
        lastImagePreviewDuration = nil
        lastImageProxyCount = 0
        let started = Date()

#if os(macOS)
        let sourceURL = fileURL ?? workDir.appending(path: "unsaved-\(sessionID)/document.tex")
        try? FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let root = documentRoot(for: sourceURL)
        let resources = Bundle.main.resourceURL?.path ?? ""
        do {
            let draft = try await draftCompiler.compile(
                source: source, sourceURL: sourceURL, engine: selectedEngine,
                warmRoot: root.appending(path: "warm", directoryHint: .isDirectory),
                stageDir: stageDir(for: sourceURL, generation: generation, stage: "draft"),
                resources: resources, useWarm: useWarmEngine && fileURL != nil
            )
            guard generation == previewGeneration else { return }
            lastDraftDuration = -started.timeIntervalSinceNow
            publish(draft)
            errorMessages = [:]

            let plan = ImagePreviewProject.plan(source: source, sourceURL: sourceURL,
                                                recorderURL: draft.recorderURL)
            guard plan.hasGraphics, fileURL != nil else {
                previewState = .ready
                return
            }

            previewState = .loadingImages
            let imageStage = stageDir(for: sourceURL, generation: generation, stage: "images")
            let cache = workDir.appending(path: "image-proxies", directoryHint: .isDirectory)
            imagePreviewTask = Task { [weak self] in
                guard let self else { return }
                await self.finishImagePreview(plan: plan, source: source, sourceURL: sourceURL,
                                              engine: selectedEngine, stageDir: imageStage,
                                              cacheDir: cache, draft: draft,
                                              generation: generation)
            }
        } catch {
            guard generation == previewGeneration else { return }
            previewState = .failed
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            errorMessages = (error as? CompilerError).map(Self.errorMessages(from:)) ?? [:]
        }
#elseif ITEX_TECTONIC
        let tex = workDir.appending(path: "document.tex")
        do {
            try Data(source.utf8).write(to: tex)
            let result = try await TectonicBackend().compile(texPath: tex, cwd: workDir, outDir: workDir,
                                                             engine: selectedEngine, profile: .fastPreview)
            guard generation == previewGeneration else { return }
            lastDraftDuration = -started.timeIntervalSinceNow
            publish(result)
            previewState = .ready
        } catch {
            guard generation == previewGeneration else { return }
            previewState = .failed
            errorMessage = error.localizedDescription
        }
#else
        guard generation == previewGeneration else { return }
        previewState = .failed
        errorMessage = CompilerError.platformUnsupported.displayMessage
#endif
    }

#if os(macOS)
    private func finishImagePreview(plan: ImagePreviewPlan, source: String, sourceURL: URL,
                                    engine: TexEngine, stageDir: URL, cacheDir: URL,
                                    draft: CompileResult, generation: UInt64) async {
        let started = Date()
        do {
            let enhanced = try await ImagePreviewProject.compile(
                plan: plan, source: source, sourceURL: sourceURL, engine: engine,
                stageDir: stageDir, cacheDir: cacheDir, draftResult: draft
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            lastImagePreviewDuration = -started.timeIntervalSinceNow
            lastImageProxyCount = enhanced.proxyCount
            publish(enhanced.result)
            previewState = .ready
            imagePreviewTask = nil
        } catch {
            guard !Task.isCancelled, generation == previewGeneration else { return }
            lastImagePreviewDuration = -started.timeIntervalSinceNow
            imagePreviewError = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            // The successful draft remains visible and its SyncTeX remains installed.
            previewState = .ready
            imagePreviewTask = nil
        }
    }

    private func compileFinal(source: String) async {
        let generation = nextGeneration()
        let selectedEngine = Self.detectEngine(source)
        engine = selectedEngine
        isFinalBuilding = true
        previewState = pdfURL == nil ? .buildingDraft : .ready
        errorMessage = nil
        imagePreviewError = nil
        defer { isFinalBuilding = false }

        let sourceURL = fileURL ?? workDir.appending(path: "unsaved-\(sessionID)/document.tex")
        let stage = stageDir(for: sourceURL, generation: generation, stage: "final")
        let sourceDir = stage.appending(path: "source", directoryHint: .isDirectory)
        let work = stage.appending(path: "work", directoryHint: .isDirectory)
        let tex = sourceDir.appending(path: sourceURL.deletingPathExtension().lastPathComponent + "-itexfinal.tex")
        do {
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: tex, options: .atomic)
            let raw = try await LatexmkBackend().compile(
                texPath: tex, cwd: sourceURL.deletingLastPathComponent(), outDir: work,
                engine: selectedEngine, profile: .finalCompile
            )
            let result = try CompilePublication.publish(raw, into: stage)
            guard generation == previewGeneration else { return }
            publish(result)
            exportPDF(from: result.pdfURL)
            errorMessages = [:]
            previewState = .ready
        } catch {
            guard generation == previewGeneration else { return }
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            errorMessages = (error as? CompilerError).map(Self.errorMessages(from:)) ?? [:]
            if pdfURL == nil { previewState = .failed }
        }
    }
#else
    private func compileFinal(source: String) async {
        // Tectonic builds do not export on iOS; retain the same generation/stale semantics.
        await compilePreview(source: source)
    }
#endif

    // MARK: - SyncTeX (docs/04 §4.3)

#if os(macOS)
    /// Forward search: locate the PDF region for an editor line (defaults to the cursor line).
    /// A soft-wrapped source line (long paragraph) yields one SyncTeX record per typeset row —
    /// `fraction` (0 = first row, 1 = last) picks the row matching the editor viewport center,
    /// so the PDF centers on the row actually on screen, not the paragraph start.
    func forwardSearch(line: Int? = nil, fraction: CGFloat = 0.5) async {
        guard let pdfURL, let texFile = compiledTexURL ?? fileURL else { return }
        let heights = PDFPageHeights(url: pdfURL)
        let results = await SyncTeXService.forward(
            line: line ?? cursorLine, texFile: texFile, pdf: pdfURL,
            pageHeight: { heights.height(page: $0) })
        guard !results.isEmpty else { return }
        // Records arrive unsorted and may span pages: order top-to-bottom (page, then y-down),
        // pick by fraction, and highlight that row's page.
        let ordered = results.sorted {
            ($0.page, -$0.rect.midY) < ($1.page, -$1.rect.midY)   // PDF y-up → -midY sorts top-first
        }
        let idx = Int((fraction * CGFloat(ordered.count - 1)).rounded())
        let chosen = ordered[min(max(idx, 0), ordered.count - 1)]
        syncToken += 1
        forwardHighlight = ForwardHighlight(page: chosen.page, rects: [chosen.rect], token: syncToken)
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
    func shutdownWarm() async {
        imagePreviewTask?.cancel()
        await draftCompiler.shutdown()
    }
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
