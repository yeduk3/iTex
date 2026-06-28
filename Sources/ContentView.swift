import SwiftUI

struct ContentView: View {
    @Binding var document: LaTeXDocument
    let fileURL: URL?
    @State private var compiler      = LaTeXCompiler()
    @State private var linter        = ChkTexLinter()
    @State private var texLabClient  = TexLabClient()
    @State private var shortcuts     = ShortcutStore.shared
    // true = editor/preview stacked top–bottom; false = side by side. Settings ⌘,.
    @AppStorage("previewSplitVertical") private var verticalSplit = false

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
            .onReceive(NotificationCenter.default.publisher(for: .iTexDidSave)) { _ in
                // Compile-on-save (replaces per-keystroke compile).
                Task { await compiler.compile(source: document.source, profile: .fastPreview) }
                if let url = fileURL { Task { await linter.lint(fileURL: url) } }
            }
            .onDisappear {
                texLabClient.stop()
#if os(macOS)
                Task { await compiler.shutdownWarm() }
#endif
            }
    }

    @ViewBuilder
    private var splitLayout: some View {
#if os(macOS)
        if verticalSplit {
            VSplitView {
                EditorView(source: $document.source, compiler: compiler,
                           linter: linter, texLabClient: texLabClient)
                    .frame(minHeight: 200)
                PDFPreviewView(compiler: compiler)
                    .frame(minHeight: 200)
            }
            .frame(minWidth: 700, minHeight: 500)
        } else {
            HSplitView {
                EditorView(source: $document.source, compiler: compiler,
                           linter: linter, texLabClient: texLabClient)
                    .frame(minWidth: 280)
                PDFPreviewView(compiler: compiler)
                    .frame(minWidth: 280)
            }
            .frame(minWidth: 700, minHeight: 500)
        }
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
                .keyboardShortcut(shortcuts.combo(.forwardSync).keyboardShortcut)
                .help("SyncTeX: jump to cursor in PDF, centered (\(shortcuts.combo(.forwardSync).display)). ⌘-click the PDF for reverse.")
        }
        ToolbarItem(placement: .automatic) {
            Button { compiler.scrollSyncEnabled.toggle() } label: {
                Label("Scroll Sync", systemImage: compiler.scrollSyncEnabled
                      ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .keyboardShortcut(shortcuts.combo(.scrollSyncToggle).keyboardShortcut)
            .help("Scroll sync (\(shortcuts.combo(.scrollSyncToggle).display)): keep the editor and PDF viewport centers aligned (bidirectional)")
            .foregroundStyle(compiler.scrollSyncEnabled ? Color.accentColor : Color.primary)
        }
#endif
        ToolbarItem(placement: .automatic) {
            if compiler.isCompiling {
                ProgressView().controlSize(.small).help("Compiling…")
            } else {
                Button { Task { await compiler.compile(source: document.source, profile: .finalCompile) } }
                    label: { Label("Build", systemImage: "hammer") }
                    .keyboardShortcut(shortcuts.combo(.build).keyboardShortcut)
                    .help("Final build: full-res images, rerun-until-stable + biber (\(shortcuts.combo(.build).display))")
            }
        }
    }
}
