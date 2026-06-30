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
        source = Self.tabifyLeadingIndent(string)
    }

    /// Convert each pair of leading spaces to a tab (structural indent → tabs), skipping
    /// verbatim-like blocks where leading spaces are literal content. In-memory only until
    /// the user edits + saves, so an untouched file is never rewritten on disk.
    /// ponytail: leading-only, pairs of spaces (4-space indent → 2 tabs). Verbatim guard covers
    /// verbatim/lstlisting/minted/alltt — extend the regex if you use other literal envs.
    static func tabifyLeadingIndent(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []; out.reserveCapacity(lines.count)
        var inVerbatim = false
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            let isEnd = verbatimEnd.firstMatch(in: line, range: r) != nil
            if isEnd { inVerbatim = false }
            out.append(inVerbatim ? line : tabifyLine(line))
            if !isEnd, verbatimBegin.firstMatch(in: line, range: r) != nil { inVerbatim = true }
        }
        return out.joined(separator: "\n")
    }

    private static func tabifyLine(_ line: String) -> String {
        var converted = "", spaceRun = 0, i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            if line[i] == " " {
                spaceRun += 1
                if spaceRun == 2 { converted += "\t"; spaceRun = 0 }
            } else {
                if spaceRun == 1 { converted += " "; spaceRun = 0 }   // flush a stray odd space
                converted += "\t"
            }
            i = line.index(after: i)
        }
        if spaceRun == 1 { converted += " " }
        return converted + String(line[i...])
    }

    private static let verbatimBegin = try! NSRegularExpression(
        pattern: #"^\s*\\begin\s*\{\s*(verbatim\*?|Verbatim|lstlisting|minted|alltt)\s*\}"#)
    private static let verbatimEnd = try! NSRegularExpression(
        pattern: #"^\s*\\end\s*\{\s*(verbatim\*?|Verbatim|lstlisting|minted|alltt)\s*\}"#)

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
