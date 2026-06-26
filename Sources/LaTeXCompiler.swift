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
    var compilationID = 0
    var engine: TexEngine = .xelatex
    var fileURL: URL?

    /// Opt-in pdflatex warm-format backend (docs/03 §3.2). Ignored for xelatex/lualatex.
    var useWarmEngine = false

    // SyncTeX state
    var cursorLine = 1
    var forwardHighlight: ForwardHighlight?
    var selectLineRequest: SelectLineRequest?
    private var syncToken = 0

    private var debounceTask: Task<Void, Never>?
    private let workDir: URL

    init() {
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "itex-build", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
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
        isCompiling = true
        errorMessage = nil
        defer { isCompiling = false }

        do {
            let result = try await buildPDF(source: source, profile: profile)
            pdfURL = result.pdfURL
            synctexURL = result.synctexURL
            compilationID += 1
        } catch {
            errorMessage = (error as? CompilerError)?.displayMessage ?? error.localizedDescription
        }
    }

    private func buildPDF(source: String, profile: CompileProfile) async throws -> CompileResult {
#if os(macOS)
        let texPath: URL, workingDir: URL
        if let fileURL {
            // Compile in-place (standard editor behavior) so \includegraphics/\input relative
            // paths resolve. Pre-compile save.
            try Data(source.utf8).write(to: fileURL)
            texPath = fileURL
            workingDir = fileURL.deletingLastPathComponent()
        } else {
            let tex = workDir.appending(path: "document.tex")
            try Data(source.utf8).write(to: tex)
            texPath = tex
            workingDir = workDir
        }

        let backend: CompileBackend =
            (useWarmEngine && engine == .pdflatex && profile == .fastPreview)
            ? PrecompiledFormatBackend()
            : LatexmkBackend()
        return try await backend.compile(texPath: texPath, workingDir: workingDir, engine: engine, profile: profile)
#elseif ITEX_TECTONIC
        // iOS: in-process Tectonic (no subprocess). Requires the FFI lib + a shipped local bundle.
        let tex = workDir.appending(path: "document.tex")
        try Data(source.utf8).write(to: tex)
        return try await TectonicBackend().compile(texPath: tex, workingDir: workDir, engine: engine, profile: profile)
#else
        // iOS without the Tectonic lib linked yet.
        throw CompilerError.platformUnsupported
#endif
    }

    // MARK: - SyncTeX (docs/04 §4.3)

#if os(macOS)
    /// Forward search: highlight the PDF region for the current editor cursor line.
    func forwardSearch() async {
        guard let pdfURL, let fileURL else { return }
        let heights = PDFPageHeights(url: pdfURL)
        let results = await SyncTeXService.forward(
            line: cursorLine, texFile: fileURL, pdf: pdfURL,
            pageHeight: { heights.height(page: $0) })
        guard let page = results.first?.page else { return }
        syncToken += 1
        forwardHighlight = ForwardHighlight(page: page, rects: results.filter { $0.page == page }.map(\.rect), token: syncToken)
    }

    /// Inverse search: a PDF click → move the editor selection to that source line.
    func inverseSearch(page: Int, point: CGPoint, pageHeight: CGFloat) async {
        guard let pdfURL else { return }
        guard let hit = await SyncTeXService.inverse(page: page, point: point, pageHeight: pageHeight, pdf: pdfURL)
        else { return }
        syncToken += 1
        selectLineRequest = SelectLineRequest(line: hit.line, token: syncToken)
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
