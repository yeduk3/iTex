import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let latexSource = UTType(exportedAs: "org.latex.tex", conformingTo: .plainText)
}

extension Notification.Name {
    /// Posted when the document is written to disk (⌘S / autosave) — drives compile-on-save.
    static let iTexDidSave = Notification.Name("iTexDidSave")
}

struct LaTeXDocument: FileDocument {
    var source: String

    static var readableContentTypes: [UTType] { [.latexSource, .plainText] }
    static var writableContentTypes: [UTType] { [.latexSource] }

    init(source: String = defaultSource) {
        self.source = source
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        source = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(source.utf8)
        // Compile-on-save: notify on the main actor (writing happens off-main).
        DispatchQueue.main.async { NotificationCenter.default.post(name: .iTexDidSave, object: nil) }
        return FileWrapper(regularFileWithContents: data)
    }
}

private let defaultSource = #"""
\documentclass{article}
\usepackage{amsmath}

\title{Untitled}
\author{}
\date{}

\begin{document}
\maketitle

Hello, \LaTeX!

\end{document}
"""#
