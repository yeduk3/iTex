import SwiftUI

struct ContentView: View {
    @Binding var document: LaTeXDocument
    let fileURL: URL?
    @State private var compiler      = LaTeXCompiler()
    @State private var linter        = ChkTexLinter()
    @State private var texLabClient  = TexLabClient()

    var body: some View {
        splitLayout
            .toolbar { toolbarContent }
            .task {
                compiler.fileURL = fileURL

                // Start texlab LSP if file is saved
                if let url = fileURL {
                    texLabClient.start(workspaceURL: url.deletingLastPathComponent())
                    // Poll for ready (max 3s) then open document
                    for _ in 0..<30 {
                        if texLabClient.isReady { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if texLabClient.isReady {
                        texLabClient.openDocument(url: url, text: document.source)
                    }
                }

                await compiler.compile(source: document.source)
                if let url = fileURL { await linter.lint(fileURL: url) }
            }
            .onChange(of: fileURL) { _, url in
                compiler.fileURL = url
            }
            .onDisappear { texLabClient.stop() }
    }

    @ViewBuilder
    private var splitLayout: some View {
#if os(macOS)
        HSplitView {
            EditorView(source: $document.source, compiler: compiler,
                       linter: linter, texLabClient: texLabClient)
                .frame(minWidth: 280)
            PDFPreviewView(compiler: compiler)
                .frame(minWidth: 280)
        }
        .frame(minWidth: 700, minHeight: 500)
#else
        HStack(spacing: 0) {
            EditorView(source: $document.source, compiler: compiler,
                       linter: linter, texLabClient: nil)
            Divider()
            PDFPreviewView(compiler: compiler)
        }
#endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("Engine", selection: $compiler.engine) {
                ForEach(TexEngine.allCases) { e in Text(e.label).tag(e) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("LaTeX engine")
        }
        ToolbarItem(placement: .automatic) {
            if !linter.warnings.isEmpty {
                let errors   = linter.warnings.filter(\.isError).count
                let warnings = linter.warnings.filter { !$0.isError }.count
                HStack(spacing: 4) {
                    if errors   > 0 { Label("\(errors)",   systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                .font(.caption)
                .help(linter.warnings.prefix(5).map { "L\($0.line): \($0.message)" }.joined(separator: "\n"))
            }
        }
#if os(macOS)
        ToolbarItem(placement: .automatic) {
            Button { Task { await compiler.forwardSearch() } }
                label: { Label("Sync", systemImage: "scope") }
                .keyboardShortcut("j", modifiers: [.command])
                .help("SyncTeX: jump to cursor in PDF (⌘J). ⌘-click the PDF for reverse.")
        }
#endif
        ToolbarItem(placement: .automatic) {
            if compiler.isCompiling {
                ProgressView().controlSize(.small).help("Compiling…")
            } else {
                Button { Task { await compiler.compile(source: document.source, profile: .finalCompile) } }
                    label: { Label("Build", systemImage: "hammer") }
                    .keyboardShortcut("b", modifiers: [.command])
                    .help("Final build: full-res images, rerun-until-stable + biber (⌘B)")
            }
        }
    }
}
