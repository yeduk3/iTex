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
    @AppStorage("splitFractionH") private var splitFractionH = 0.5   // editor share, side-by-side
    @AppStorage("splitFractionV") private var splitFractionV = 0.5   // editor share, stacked
#if os(macOS)
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
#endif

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
        // NavigationSplitView (macOS standard, like qmd): the built-in toggle lives in the
        // sidebar and animates reveal/collapse natively — we keep it as the single button.
        // ⌘\ drives the same animated toggle via a hidden shortcut (no second visible button).
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(root: fileURL?.deletingLastPathComponent(), currentFile: fileURL)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            editorPreviewSplit
                .frame(minWidth: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        .background {
            Button("Toggle Sidebar", action: toggleSidebar)
                .keyboardShortcut(shortcuts.combo(.toggleSidebar).keyboardShortcut)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear { columnVisibility = showSidebar ? .all : .doubleColumn }
        .onChange(of: columnVisibility) { _, v in showSidebar = (v != .detailOnly) }
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
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .doubleColumn : .detailOnly
        }
    }

    private var editorPreviewSplit: some View {
        // Custom split (not HSplitView): SwiftUI's divider grab zone is ~1px and unconfigurable.
        DraggableSplit(vertical: verticalSplit,
                       fraction: verticalSplit ? $splitFractionV : $splitFractionH) {
            EditorView(source: $document.source, compiler: compiler,
                       linter: linter, texLabClient: texLabClient)
        } second: {
            PDFPreviewView(compiler: compiler)
        }
    }
#endif

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
        ToolbarItem(placement: .automatic) {
            Button { Task { await compiler.cleanBuild(source: document.source) } }
                label: { Label("Clean Build", systemImage: "arrow.triangle.2.circlepath") }
                .keyboardShortcut(shortcuts.combo(.cleanBuild).keyboardShortcut)
                .disabled(compiler.isCompiling)
                .help("Clean build: wipe cached artifacts, then full compile (\(shortcuts.combo(.cleanBuild).display))")
        }
    }
}

#if os(macOS)
import AppKit
import CoreServices

// MARK: - Resizable split with a wide grab zone

/// Two panes with a draggable divider whose hit area is `handle`-wide (vs HSplitView's ~1px),
/// so the boundary is easy to grab. `fraction` is the first pane's share, persisted by the caller.
private struct DraggableSplit<First: View, Second: View>: View {
    let vertical: Bool
    @Binding var fraction: Double
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    private let handle: CGFloat = 10
    private let minFrac = 0.15
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.height : geo.size.width
            let f = min(max(fraction, minFrac), 1 - minFrac)
            let firstLen = total * f
            if vertical {
                VStack(spacing: 0) {
                    first().frame(height: firstLen)
                    divider(total: total)
                    second()
                }
            } else {
                HStack(spacing: 0) {
                    first().frame(width: firstLen)
                    divider(total: total)
                    second()
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Color.clear
            .frame(width: vertical ? nil : handle, height: vertical ? handle : nil)
            .frame(maxWidth: vertical ? .infinity : nil, maxHeight: vertical ? nil : .infinity)
            .overlay(Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let start = dragStart ?? fraction
                        if dragStart == nil { dragStart = start }
                        let delta = Double((vertical ? v.translation.height : v.translation.width)) / Double(total)
                        fraction = min(max(start + delta, minFrac), 1 - minFrac)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

// MARK: - Sidebar (ported from qmd: DisclosureGroup + lazy children + FSEvents watcher)

/// Watches a directory tree via FSEvents and fires `onChange` (coalesced) on any create /
/// delete / rename / modify under it — including changes from external apps (Finder).
private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start(url: URL) {
        if stream != nil, watchedPath == url.path { return }   // no-op if already watching
        stop()
        watchedPath = url.path
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx,
            [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil; watchedPath = nil
    }

    deinit { stop() }
}

/// Bumped whenever the watched folder changes on disk so the tree re-reads.
private final class FileTreeModel: ObservableObject {
    @Published var version = 0
    private lazy var watcher = DirectoryWatcher { [weak self] in self?.reload() }
    func reload() { version &+= 1 }
    func watch(_ url: URL?) { if let url { watcher.start(url: url) } else { watcher.stop() } }
}

/// Disclosure state, one source of truth so folders stay expanded across re-reads.
/// ponytail: in-memory only — resets on relaunch. Persist to UserDefaults if it should survive.
private final class SidebarExpansion: ObservableObject {
    static let shared = SidebarExpansion()
    @Published var expanded: Set<URL> = []
}

private struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var id: URL { url }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "pdf", "gif", "tiff", "tif", "bmp", "heic"]
    var isImage: Bool { FileEntry.imageExts.contains(url.pathExtension.lowercased()) }
    var isTex: Bool { url.pathExtension.lowercased() == "tex" }

    static func children(of dir: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> FileEntry? in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(url: url, name: vals?.name ?? url.lastPathComponent,
                             isDirectory: vals?.isDirectory ?? false)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }   // dirs first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Left sidebar: native `.sidebar` file tree rooted at the open .tex file's directory.
/// Folder name is the section header; selecting an image row previews it (same popover style).
struct SidebarView: View {
    let root: URL?
    let currentFile: URL?
    @StateObject private var tree = FileTreeModel()
    @State private var selection: URL?
    @State private var preview: FileEntry?

    var body: some View {
        Group {
            if let root {
                List(selection: $selection) {
                    Section(root.lastPathComponent.removingPercentEncoding ?? root.lastPathComponent) {
                        ForEach(FileEntry.children(of: root)) { entry in
                            FileRow(entry: entry, currentFile: currentFile, tree: tree)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder",
                    description: Text("Open a .tex file to browse its folder."))
            }
        }
        .onAppear { tree.watch(root); selection = currentFile }
        .onChange(of: root) { _, new in tree.watch(new) }
        .onChange(of: currentFile) { _, f in selection = f }
        // Single click selects; an image selection previews it (reliable where a row
        // TapGesture gets swallowed by the table's own mouse tracking).
        .onChange(of: selection) { _, url in
            guard let url, FileEntry.imageExts.contains(url.pathExtension.lowercased()) else { return }
            preview = FileEntry(url: url, name: url.lastPathComponent, isDirectory: false)
        }
        .popover(item: $preview) { entry in
            if let img = NSImage(contentsOf: entry.url) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 360).padding(8)
            } else {
                Text("Cannot preview \(entry.name)").padding()
            }
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel
    @ObservedObject private var expansion = SidebarExpansion.shared
    @State private var children: [FileEntry] = []

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expansion.expanded.contains(entry.url) },
            set: { if $0 { expansion.expanded.insert(entry.url) } else { expansion.expanded.remove(entry.url) } }
        )
    }
    private func reloadChildrenIfExpanded() {
        children = expansion.expanded.contains(entry.url) ? FileEntry.children(of: entry.url) : []
    }
    private var isCurrent: Bool {
        currentFile?.standardizedFileURL == entry.url.standardizedFileURL
    }

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(children) { FileRow(entry: $0, currentFile: currentFile, tree: tree) }
            } label: {
                Label(entry.name, systemImage: "folder").lineLimit(1)
            }
            .tag(entry.url)
            .onAppear { reloadChildrenIfExpanded() }
            .onChange(of: expansion.expanded) { _, _ in reloadChildrenIfExpanded() }
            .onChange(of: tree.version) { _, _ in reloadChildrenIfExpanded() }
            .contextMenu { revealButton }
        } else {
            Label {
                Text(entry.name).lineLimit(1)
            } icon: {
                Image(systemName: entry.isImage ? "photo" : entry.isTex ? "doc.text" : "doc")
                    .foregroundStyle(entry.isTex ? Color.accentColor : Color.secondary)
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .tag(entry.url)
            .contextMenu { revealButton }
        }
    }

    private var revealButton: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }
}
#endif
