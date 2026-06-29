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
    @AppStorage("showSidebar") private var showSidebar = true

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
        HSplitView {
            if showSidebar, let root = fileURL?.deletingLastPathComponent() {
                SidebarView(root: root)
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 360)
            }
            editorPreviewSplit
                .frame(minWidth: 560)
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

#if os(macOS)
    @ViewBuilder
    private var editorPreviewSplit: some View {
        if verticalSplit {
            VSplitView {
                EditorView(source: $document.source, compiler: compiler,
                           linter: linter, texLabClient: texLabClient)
                    .frame(minHeight: 200)
                PDFPreviewView(compiler: compiler)
                    .frame(minHeight: 200)
            }
        } else {
            HSplitView {
                EditorView(source: $document.source, compiler: compiler,
                           linter: linter, texLabClient: texLabClient)
                    .frame(minWidth: 280)
                PDFPreviewView(compiler: compiler)
                    .frame(minWidth: 280)
            }
        }
    }
#endif

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
#if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button { showSidebar.toggle() } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut(shortcuts.combo(.toggleSidebar).keyboardShortcut)
            .help("Show/hide the file sidebar (\(shortcuts.combo(.toggleSidebar).display))")
        }
#endif
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

#if os(macOS)
import AppKit

private let previewableImageExts: Set<String> =
    ["png", "jpg", "jpeg", "pdf", "gif", "tiff", "tif", "bmp", "heic"]

/// A file/dir in the sidebar tree. `children == nil` ⇒ leaf (file); built eagerly on first show.
private struct FileNode: Identifiable {
    let url: URL
    var children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isDir: Bool { children != nil }
    var isImage: Bool { previewableImageExts.contains(url.pathExtension.lowercased()) }

    // ponytail: built once, no FSEvents watcher — Refresh button rescans. Depth-capped to avoid runaway.
    static func build(_ url: URL, depth: Int = 0) -> FileNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir, depth < 8 else { return FileNode(url: url, children: nil) }
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = kids
            .map { build($0, depth: depth + 1) }
            .sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }          // dirs first
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        return FileNode(url: url, children: nodes)
    }
}

/// Left sidebar: a file tree rooted at the open .tex file's directory. Clicking an image previews it.
struct SidebarView: View {
    let root: URL
    @State private var tree: FileNode?
    @State private var preview: FileNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(root.lastPathComponent).font(.caption).bold().lineLimit(1)
                Spacer()
                Button { tree = FileNode.build(root) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            List {
                if let children = tree?.children {
                    OutlineGroup(children, id: \.id, children: \.children) { node in
                        row(node)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear { if tree == nil { tree = FileNode.build(root) } }
        .onChange(of: root) { _, new in tree = FileNode.build(new) }
        .popover(item: $preview) { node in
            if let img = NSImage(contentsOf: node.url) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 360)
                    .padding(8)
            } else {
                Text("Cannot preview \(node.name)").padding()
            }
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        Label(node.name, systemImage: icon(node))
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { if node.isImage { preview = node } }
    }

    private func icon(_ node: FileNode) -> String {
        if node.isDir { return "folder" }
        if node.isImage { return "photo" }
        if node.url.pathExtension.lowercased() == "tex" { return "doc.text" }
        return "doc"
    }
}
#endif
