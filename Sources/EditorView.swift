import SwiftUI

struct EditorView: View {
    @Binding var source: String
    let compiler: LaTeXCompiler
    let linter: ChkTexLinter
    var texLabClient: TexLabClient?

    /// Compile-failure messages + chktex errors, keyed by source line.
    private var mergedErrors: [Int: String] {
        var m = compiler.errorMessages
        for w in linter.warnings where w.isError {
            m[w.line] = m[w.line].map { $0 + "\n" + w.message } ?? w.message
        }
        return m
    }

    var body: some View {
        // Errors surface inline (red line + hover/⌘. popover). Full-message banner removed
        // — compiler.errorMessage kept for a future dedicated panel.
        LaTeXEditorView(text: $source, texLabClient: texLabClient, compiler: compiler,
                        errorMessages: mergedErrors,
                        selectReq: compiler.selectLineRequest, scrollReq: compiler.scrollToLineRequest)
            .onChange(of: source) { _, new in
                // Keep the LSP in sync live (completions need it); compile/lint moved to save.
                texLabClient?.changeDocument(text: new)
            }
    }
}
