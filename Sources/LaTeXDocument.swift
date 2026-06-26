import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let latexSource = UTType(exportedAs: "org.latex.tex", conformingTo: .plainText)
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
        FileWrapper(regularFileWithContents: Data(source.utf8))
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
