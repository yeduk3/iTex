import Foundation

// ponytail: the CLI reuses the real engine (CompileEngine.swift, SyncTeX.swift via symlink) but
// not the SwiftUI/PDFKit app types. These two tiny enums are the only app types the engine needs,
// re-declared here so the CLI doesn't pull in Observation/PDFKit. Keep in sync with LaTeXCompiler.swift.

enum TexEngine: String, CaseIterable {
    case xelatex, pdflatex, lualatex
}

enum CompilerError: LocalizedError {
    case buildFailed(String)
    case platformUnsupported
    var errorDescription: String? {
        switch self {
        case .buildFailed(let log): return log
        case .platformUnsupported: return "unsupported platform"
        }
    }
}
