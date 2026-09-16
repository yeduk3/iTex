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
    /// Includes the image-enhancement pass: it also owns a TeX subprocess and must be stoppable
    /// from the Build command if it becomes wedged.
    var isCompiling: Bool { activeCompileTask != nil || previewState == .loadingImages || isRestarting }
    /// A clean restart has already been accepted and is stopping/cleaning before its replacement
    /// compile starts. Repeated UI commands during this short phase are idempotent.
    var restartInProgress: Bool { isRestarting }
    /// Exactly the condition under which `compile` runs instead of dropping the request. Unlike
    /// `isCompiling`, an image-enhancement pass doesn't block (a new compile supersedes it).
    var acceptsCompileRequest: Bool { activeCompileTask == nil && !isRestarting }
    var errorMessage: String?
    var imagePreviewError: String?
    var errorMessages: [Int: String] = [:]   // 1-based source line → error text, from last failed build
    var buildDiagnostics: [Diagnostic] = []
    var compilationID = 0
    private(set) var previewGeneration: UInt64 = 0
    private(set) var lastDraftDuration: TimeInterval?
    private(set) var lastImagePreviewDuration: TimeInterval?
    private(set) var lastImageProxyCount = 0
    // Auto-detected from the document each compile (detectEngine) — no engine picker.
    // All engines share the warm pre-started fast path; fontspec/CJK docs auto-route to xelatex.
    var engine: TexEngine = .pdflatex
    /// The file displayed by this editor. Keep this distinct from `mainFileURL`.
    var fileURL: URL?
    private(set) var projectContext: LaTeXProjectContext?
    var mainFileURL: URL? { projectContext?.mainFile ?? fileURL }
    var projectDirectory: URL? {
        projectContext?.projectDirectory ?? fileURL?.deletingLastPathComponent()
    }
    /// Called when inverse SyncTeX lands in a different file in the same project.
    var onNavigateToSource: ((URL, Int) -> Void)?

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
    private var activeCompileTask: Task<Void, Never>?
    private var activeCompileToken: UInt64 = 0
    private var isRestarting = false
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

    func configureProject(_ context: LaTeXProjectContext?) {
        projectContext = context
        if let context { fileURL = context.currentFile }
        refreshInlineDiagnostics()
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
        // Save/open notifications can arrive while a build is already running. Do not enqueue
        // stale sources behind a slow compiler or overlap scratch-directory writes; an explicit
        // user restart goes through `forceCleanRestart` below.
        guard activeCompileTask == nil, !isRestarting else { return }
        activeCompileToken &+= 1
        let token = activeCompileToken
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch profile {
            case .fastPreview, .imagePreview:
                await self.compilePreview(source: source)
            case .finalCompile:
                await self.compileFinal(source: source)
            }
        }
        activeCompileTask = task
        await task.value
        guard token == activeCompileToken else { return }
        activeCompileTask = nil
    }

    /// Parse build errors with their actual source file. Relative paths are rooted at the main
    /// document directory; the private root build-copy is mapped back to the user's main file.
    nonisolated static func diagnostics(from error: CompilerError, mainFile: URL?,
                                        compiledRoot: URL? = nil) -> [Diagnostic] {
        guard case .buildFailed(let log) = error else { return [] }
        var out: [Diagnostic] = []
        let nsLog = log as NSString
        let full = NSRange(location: 0, length: nsLog.length)

        let fileLine = try! NSRegularExpression(
            pattern: #"(?m)^(?:\((?=[^)]*\.tex:))?(.+?\.tex):(\d+):\s*(.+)$"#
        )
        for m in fileLine.matches(in: log, range: full) {
            guard let n = Int(nsLog.substring(with: m.range(at: 2))) else { continue }
            var path = nsLog.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("(") { path.removeFirst() }
            let rawURL = URL(filePath: path, relativeTo: mainFile?.deletingLastPathComponent())
                .standardizedFileURL
            let mappedURL: URL?
            if let compiledRoot,
               rawURL == compiledRoot.standardizedFileURL {
                mappedURL = mainFile?.standardizedFileURL
            } else {
                mappedURL = rawURL
            }
            let message = nsLog.substring(with: m.range(at: 3))
                .trimmingCharacters(in: .whitespaces)
            out.append(Diagnostic(source: .build, severity: .error, file: mappedURL,
                                  line: n, message: message))
        }
        if out.isEmpty {   // engines without -file-line-error
            let bang = try! NSRegularExpression(pattern: #"(?m)^! (.+)$"#)
            let lLine = try! NSRegularExpression(pattern: #"(?m)^l\.(\d+)\b"#)
            if let lm = lLine.firstMatch(in: log, range: full),
               let n = Int(nsLog.substring(with: lm.range(at: 1))) {
                let msg = bang.firstMatch(in: log, range: full).map { nsLog.substring(with: $0.range(at: 1)) } ?? "LaTeX error"
                out.append(Diagnostic(source: .build, severity: .error, file: mainFile,
                                      line: n, message: msg))
            }
        }
        return out
    }

    /// Compatibility helper used by the editor: only markers belonging to the active file appear
    /// inline; the Problems panel receives all `buildDiagnostics`.
    nonisolated static func errorMessages(from error: CompilerError) -> [Int: String] {
        Dictionary(grouping: diagnostics(from: error, mainFile: nil), by: \.line)
            .mapValues { $0.map(\.message).joined(separator: "\n") }
    }

    /// Force a clean rebuild: discard the document's cached build artifacts (latexmk state, aux,
    /// stale PDF), then run a full compile from scratch.
    func cleanBuild(source: String) async {
        // Use the same managed sequence as a confirmed restart. This keeps the stop/cleanup phase
        // visible to the command router and prevents an untracked cleanup from racing Build.
        await forceCleanRestart(source: source)
    }

    /// Stop the exact build owned by this document, wait for its TeX process to exit, discard warm
    /// state, and only then launch a fresh final compile. The generation/token bumps prevent an old
    /// completion or `defer` from clearing/publishing over the replacement run.
    func forceCleanRestart(source: String) async {
        guard !isRestarting else { return }
        isRestarting = true
        debounceTask?.cancel()
        debounceTask = nil

        let previousTask = activeCompileTask
        let previousImageTask = imagePreviewTask
        activeCompileToken &+= 1
        _ = nextGeneration()
        previousTask?.cancel()
        previousImageTask?.cancel()
        await previousTask?.value
        await previousImageTask?.value
        activeCompileTask = nil

#if os(macOS)
        await draftCompiler.shutdown()
        if let mainFileURL {
            try? FileManager.default.removeItem(at: documentRoot(for: mainFileURL).appending(path: "warm"))
        }
#endif
        settleCancelledLoadingState()
        isRestarting = false
        await compile(source: source, profile: .finalCompile)
    }

    private func settleCancelledLoadingState() {
        isFinalBuilding = false
        if previewState == .buildingDraft || previewState == .loadingImages {
            previewState = pdfURL == nil ? .idle : .ready
        }
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
        guard let mainFileURL else { return }
        let dest = mainFileURL.deletingPathExtension().appendingPathExtension("pdf")
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

    private func compilationInput(editorSource: String) -> (source: String, url: URL) {
        guard let context = projectContext else {
            return (editorSource, fileURL ?? workDir.appending(path: "unsaved-\(sessionID)/document.tex"))
        }
        if context.isEditingMainFile { return (editorSource, context.mainFile) }
        let rootSource = (try? String(contentsOf: context.mainFile, encoding: .utf8))
            ?? context.rootSource
        return (rootSource, context.mainFile)
    }

    private func installDiagnostics(_ error: Error, compiledRoot: URL? = nil) {
        guard let compilerError = error as? CompilerError else {
            buildDiagnostics = []
            errorMessages = [:]
            return
        }
        let parsed = Self.diagnostics(
            from: compilerError, mainFile: mainFileURL,
            compiledRoot: compiledRoot ?? compiledTexURL
        )
        buildDiagnostics = parsed
        refreshInlineDiagnostics()
    }

    /// Re-scope already parsed project diagnostics to the editor tab that is currently active.
    /// Switching source tabs must not compile (or disturb the shared PDF), but its inline
    /// annotations still need to follow the selected file.
    private func refreshInlineDiagnostics() {
        let current = fileURL?.standardizedFileURL
        errorMessages = Dictionary(
            grouping: buildDiagnostics.filter {
                guard let file = $0.file?.standardizedFileURL else { return current == nil }
                return file == current
            },
            by: \.line
        ).mapValues { $0.map(\.message).joined(separator: "\n") }
    }

    private func compilePreview(source: String) async {
        let input = compilationInput(editorSource: source)
        let generation = nextGeneration()
        let selectedEngine = Self.detectEngine(input.source)
        engine = selectedEngine
        previewState = .buildingDraft
        errorMessage = nil
        imagePreviewError = nil
        lastImagePreviewDuration = nil
        lastImageProxyCount = 0
        let started = Date()
        defer {
            // A cancelled backend may return without throwing. Never leave a current generation
            // displaying an endless spinner, but never let an old generation settle a newer one.
            if generation == previewGeneration, previewState == .buildingDraft {
                previewState = pdfURL == nil ? .idle : .ready
            }
        }

#if os(macOS)
        let sourceURL = input.url
        try? FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let root = documentRoot(for: sourceURL)
        let draftBuildTex = root.appending(path: "warm/\(sourceURL.deletingPathExtension().lastPathComponent)-itexwarm.tex")
        let resources = Bundle.main.resourceURL?.path ?? ""
        do {
            let draft = try await draftCompiler.compile(
                source: input.source, sourceURL: sourceURL, engine: selectedEngine,
                warmRoot: root.appending(path: "warm", directoryHint: .isDirectory),
                stageDir: stageDir(for: sourceURL, generation: generation, stage: "draft"),
                resources: resources, useWarm: useWarmEngine && mainFileURL != nil
            )
            guard generation == previewGeneration else { return }
            lastDraftDuration = -started.timeIntervalSinceNow
            publish(draft)
            errorMessages = [:]
            buildDiagnostics = []

            let plan = ImagePreviewProject.plan(source: input.source, sourceURL: sourceURL,
                                                recorderURL: draft.recorderURL)
            guard plan.hasGraphics, mainFileURL != nil else {
                previewState = .ready
                return
            }

            previewState = .loadingImages
            let imageStage = stageDir(for: sourceURL, generation: generation, stage: "images")
            let cache = workDir.appending(path: "image-proxies", directoryHint: .isDirectory)
            imagePreviewTask = Task { [weak self] in
                guard let self else { return }
                await self.finishImagePreview(plan: plan, source: input.source, sourceURL: sourceURL,
                                              engine: selectedEngine, stageDir: imageStage,
                                              cacheDir: cache, draft: draft,
                                              generation: generation)
            }
        } catch {
            guard generation == previewGeneration else { return }
            previewState = .failed
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            installDiagnostics(error, compiledRoot: draftBuildTex)
        }
#elseif ITEX_TECTONIC
        let tex = workDir.appending(path: "document.tex")
        do {
            try Data(input.source.utf8).write(to: tex)
            let result = try await TectonicBackend().compile(
                texPath: tex, cwd: input.url.deletingLastPathComponent(), outDir: workDir,
                engine: selectedEngine, profile: .fastPreview
            )
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
        let input = compilationInput(editorSource: source)
        let generation = nextGeneration()
        let selectedEngine = Self.detectEngine(input.source)
        engine = selectedEngine
        isFinalBuilding = true
        previewState = pdfURL == nil ? .buildingDraft : .ready
        errorMessage = nil
        imagePreviewError = nil
        defer {
            if generation == previewGeneration { isFinalBuilding = false }
        }

        let sourceURL = input.url
        let stage = stageDir(for: sourceURL, generation: generation, stage: "final")
        let sourceDir = stage.appending(path: "source", directoryHint: .isDirectory)
        let work = stage.appending(path: "work", directoryHint: .isDirectory)
        let tex = sourceDir.appending(path: sourceURL.deletingPathExtension().lastPathComponent + "-itexfinal.tex")
        do {
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data(input.source.utf8).write(to: tex, options: .atomic)
            let raw = try await LatexmkBackend().compile(
                texPath: tex, cwd: sourceURL.deletingLastPathComponent(), outDir: work,
                engine: selectedEngine, profile: .finalCompile
            )
            let result = try CompilePublication.publish(raw, into: stage)
            guard generation == previewGeneration else { return }
            publish(result)
            exportPDF(from: result.pdfURL)
            errorMessages = [:]
            buildDiagnostics = []
            previewState = .ready
        } catch {
            guard generation == previewGeneration else { return }
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
            installDiagnostics(error, compiledRoot: tex)
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
        guard let pdfURL else { return }
        let isMain = fileURL?.standardizedFileURL == mainFileURL?.standardizedFileURL
        guard let editorFile = fileURL else { return }
        let texFile = isMain ? (compiledTexURL ?? mainFileURL ?? editorFile)
            : syncQueryURL(for: editorFile)
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
        guard syncSourceURL(for: hit.file) == fileURL?.standardizedFileURL else { return }
        syncToken += 1
        scrollToLineRequest = SelectLineRequest(line: hit.line, token: syncToken)
    }

    /// Inverse search: a PDF click → move the editor selection to that source line.
    func inverseSearch(page: Int, point: CGPoint, pageHeight: CGFloat) async {
        guard let pdfURL else { return }
        guard let hit = await SyncTeXService.inverse(page: page, point: point, pageHeight: pageHeight, pdf: pdfURL)
        else { return }
        let hitURL = syncSourceURL(for: hit.file)
        if let hitURL, hitURL != fileURL?.standardizedFileURL {
            onNavigateToSource?(hitURL, hit.line)
            return
        }
        syncToken += 1
        selectLineRequest = SelectLineRequest(line: hit.line, token: syncToken)
    }

    /// Convert SyncTeX's absolute/relative/private-copy input into a user project path.
    func syncSourceURL(for path: String) -> URL? {
        let url = URL(filePath: path, relativeTo: projectDirectory).standardizedFileURL
        if let compiledTexURL, url == compiledTexURL.standardizedFileURL {
            return mainFileURL?.standardizedFileURL
        }
        // Image preview compiles a symlink mirror. Included inputs may be reported either as the
        // mirror path or as their resolved symlink destination; translate the former explicitly.
        if let compiledTexURL,
           compiledTexURL.deletingLastPathComponent().lastPathComponent == "project" {
            let mirror = compiledTexURL.deletingLastPathComponent().standardizedFileURL
            let prefix = mirror.path.hasSuffix("/") ? mirror.path : mirror.path + "/"
            if url.path.hasPrefix(prefix), let projectDirectory {
                let relative = String(url.path.dropFirst(prefix.count))
                return projectDirectory.appending(path: relative).standardizedFileURL
            }
        }
        return url
    }

    private func syncQueryURL(for editorFile: URL) -> URL {
        guard let compiledTexURL,
              compiledTexURL.deletingLastPathComponent().lastPathComponent == "project",
              let projectDirectory
        else { return editorFile }
        let projectPath = projectDirectory.standardizedFileURL.path
        let currentPath = editorFile.standardizedFileURL.path
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard currentPath.hasPrefix(prefix) else { return editorFile }
        let relative = String(currentPath.dropFirst(prefix.count))
        return compiledTexURL.deletingLastPathComponent()
            .appending(path: relative).standardizedFileURL
    }

    /// Terminate the parked warm engine (call on document close so it doesn't outlive the window).
    func shutdownWarm() async {
        let previousImageTask = imagePreviewTask
        activeCompileToken &+= 1
        _ = nextGeneration()
        activeCompileTask?.cancel()
        previousImageTask?.cancel()
        await activeCompileTask?.value
        await previousImageTask?.value
        activeCompileTask = nil
        await draftCompiler.shutdown()
        settleCancelledLoadingState()
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
