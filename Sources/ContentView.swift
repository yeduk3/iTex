import SwiftUI
#if os(macOS)
import NativeTerminal
#endif

struct ContentView: View {
    @Binding var document: LaTeXDocument
    let fileURL: URL?
    @State private var compiler      = LaTeXCompiler()
    @State private var linter        = ChkTexLinter()
    @State private var texLabClient  = TexLabClient()
    @State private var shortcuts     = ShortcutStore.shared
    @State private var projectContext: LaTeXProjectContext?
    @StateObject private var diagnostics = DiagnosticsStore()
    @State private var showProblems  = false
    @State private var showCompileRestartConfirmation = false
    // true = editor/preview stacked top–bottom; false = side by side. Settings ⌘,.
    @AppStorage("previewSplitVertical") private var verticalSplit = false
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("splitFractionH") private var splitFractionH = 0.5   // editor share, side-by-side
    @AppStorage("splitFractionV") private var splitFractionV = 0.5   // editor share, stacked
#if os(macOS)
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @StateObject private var quickOpen = QuickOpenController()
    @State private var terminalSessionActive = false
    @State private var terminalWorkingDirectory: URL?
    @State private var showTerminal = false
    @State private var terminalRevision = 0
    @State private var terminalFocusRequest = 0
#endif

    var body: some View {
        splitLayout
            .toolbar { toolbarContent }
            .alert("Restart Compilation?", isPresented: $showCompileRestartConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Stop & Restart", role: .destructive) {
                    Task { await compiler.forceCleanRestart(source: document.source) }
                }
            } message: {
                Text("A compilation is still running. Stop it and start a clean build from the beginning?")
            }
            .task {
                configureProject()
                texLabClient.onDiagnostics = { diagnostics.setLSP($0) }
#if os(macOS)
                compiler.onNavigateToSource = { url, line in
                    openProjectFile(url, line: line)
                }
#endif
                linter.onResults = { warnings in
                    diagnostics.setChkTex(warnings.map {
                        Diagnostic(source: .chktex, severity: $0.isError ? .error : .warning,
                                   file: fileURL, line: $0.line, message: $0.message)
                    })
                }

                // Start texlab LSP if file is saved
                if let url = fileURL {
                    await startTexLab(for: url)
                }

                await compiler.compile(source: document.source)
                if let url = fileURL { await linter.lint(fileURL: url) }
            }
            .onChange(of: fileURL) { _, url in
                compiler.fileURL = url
                configureProject()
                if let url {
                    Task { await startTexLab(for: url) }
                }
            }
            .onChange(of: compiler.buildDiagnostics) { _, diags in
                diagnostics.setBuild(diags)
                if !diags.isEmpty { showProblems = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iTexDidSave)) { notification in
                guard notification.userInfo?["documentID"] as? UUID == document.id else { return }
                // Compile-on-save (replaces per-keystroke compile).
                Task {
                    // FileDocument posts while producing the wrapper; let the coordinated disk
                    // write finish before a parent document reads this included child.
                    try? await Task.sleep(for: .milliseconds(100))
                    configureProject()
                    await compiler.compile(source: document.source, profile: .fastPreview)
                }
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
            SidebarView(root: projectDirectory, currentFile: fileURL)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                editorPreviewSplit.frame(minHeight: 180)
                if showProblems {
                    ProblemsPanel(store: diagnostics, onJump: handleProblemJump)
                }
                if terminalSessionActive, let directory = terminalWorkingDirectory {
                    EmbeddedTerminalPanel(
                        directory: directory,
                        isVisible: showTerminal,
                        revision: $terminalRevision,
                        focusRequest: $terminalFocusRequest,
                        onClose: closeTerminalSession)
                }
            }
            .frame(minWidth: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: minimumWindowHeight)
        .background {
            Button("Toggle Sidebar", action: toggleSidebar)
                .keyboardShortcut(shortcuts.combo(.toggleSidebar).keyboardShortcut)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .background(WindowAccessor(rootKey: projectDirectory?.standardizedFileURL.path ?? "none")
            .id(projectDirectory?.standardizedFileURL.path ?? "none"))
        .onAppear { columnVisibility = showSidebar ? .all : .doubleColumn }
        .onChange(of: columnVisibility) { _, v in
            showSidebar = (v != .detailOnly)
            if v == .detailOnly { SidebarPreviewPanel.shared.hide() }   // sidebar gone → its child panel would orphan
        }
        .sheet(isPresented: Binding(get: { quickOpen.isVisible },
                                    set: { if !$0 { quickOpen.hide() } })) {
            QuickOpenPalette(controller: quickOpen, onOpen: handleQuickOpen)
        }
        .focusedSceneValue(\.quickOpenAction, { quickOpen.show(root: projectDirectory) })
        .focusedSceneValue(\.problemsToggle, { showProblems.toggle() })
        .focusedSceneValue(\.projectDirectory, projectDirectory)
        .focusedSceneValue(\.embeddedTerminalToggle, terminalToggleAction)
#else
        HStack(spacing: 0) {
            EditorView(source: $document.source, compiler: compiler,
                       linter: linter, texLabClient: nil)
            Divider()
            PDFPreviewView(compiler: compiler)
        }
#endif
    }

    private var projectDirectory: URL? {
        projectContext?.projectDirectory ?? fileURL?.deletingLastPathComponent()
    }

    private func configureProject() {
        guard let fileURL else {
            projectContext = nil
            compiler.fileURL = nil
            compiler.configureProject(nil)
            return
        }
        let resolved = LaTeXProjectResolver.resolve(fileURL)
        projectContext = resolved
        compiler.configureProject(resolved)
    }

    private func startTexLab(for url: URL) async {
        texLabClient.stop()
        texLabClient.start(workspaceURL: projectDirectory ?? url.deletingLastPathComponent())
        for _ in 0..<30 {
            if texLabClient.isReady { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if texLabClient.isReady {
            texLabClient.openDocument(url: url, text: document.source)
        }
    }

#if os(macOS)
    private var terminalToggleAction: (() -> Void)? {
        guard projectDirectory != nil else { return nil }
        return toggleTerminalPanel
    }

    private var minimumWindowHeight: CGFloat {
        showTerminal && showProblems ? 650 : 500
    }

    /// Toggle panel visibility without ending an existing PTY session.
    private func toggleTerminalPanel() {
        guard projectDirectory != nil else { return }
        if !terminalSessionActive {
            terminalWorkingDirectory = projectDirectory?.standardizedFileURL
            terminalSessionActive = true
            showTerminal = true
            terminalFocusRequest &+= 1
        } else if showTerminal {
            showTerminal = false
            restoreEditorFocus()
        } else {
            showTerminal = true
            terminalFocusRequest &+= 1
        }
    }

    /// Explicit session close (X or terminal-focused Cmd+W) removes the representable and
    /// therefore invokes NativeTerminalView.dismantleNSView/terminate.
    private func closeTerminalSession() {
        guard terminalSessionActive else { return }
        showTerminal = false
        terminalSessionActive = false
        terminalWorkingDirectory = nil
        restoreEditorFocus()
    }

    private func restoreEditorFocus() {
        let window = NSApp.keyWindow
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if let editor = Self.firstVisibleEditor(in: window.contentView),
               window.makeFirstResponder(editor) {
                return
            }
            // Never leave a collapsed terminal (or one being removed) as first responder.
            window.makeFirstResponder(nil)
        }
    }

    private static func firstVisibleEditor(in view: NSView?) -> LaTeXTextView? {
        guard let view else { return nil }
        if let editor = view as? LaTeXTextView, !editor.isHiddenOrHasHiddenAncestor { return editor }
        for child in view.subviews {
            if let editor = firstVisibleEditor(in: child) { return editor }
        }
        return nil
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .doubleColumn : .detailOnly
        }
    }

    /// Open a quick-open selection. A content hit (non-nil line) parks a PendingJump and posts a
    /// jump notification so the editor lands on the line whether the document is new or already
    /// open; a filename hit opens openable files as a tab or reveals the rest in Finder.
    private func handleQuickOpen(_ url: URL, line: Int?) {
        quickOpen.hide()
        let ext = url.pathExtension.lowercased()
        if let line {
            PendingJump.shared.set(url, line: line)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
                NotificationCenter.default.post(name: .iTexJumpToLine, object: nil,
                                                userInfo: ["url": url, "line": line])
            }
        } else if QuickOpenController.openableExts.contains(ext) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openProjectFile(_ url: URL, line: Int) {
        PendingJump.shared.set(url, line: line)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
            NotificationCenter.default.post(name: .iTexJumpToLine, object: nil,
                                            userInfo: ["url": url, "line": line])
        }
    }

    /// Jump to a diagnostic's file:line — reuses the quick-open content-hit path (park a
    /// PendingJump, open the doc if needed, then post the jump notification).
    private func handleProblemJump(_ d: Diagnostic) {
        guard let url = d.file ?? fileURL else { return }
        PendingJump.shared.set(url, line: d.line)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
            NotificationCenter.default.post(name: .iTexJumpToLine, object: nil,
                                            userInfo: ["url": url, "line": d.line])
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
            let errors   = diagnostics.count(.error)
            let warnings  = diagnostics.count(.warning)
            Button { showProblems.toggle() } label: {
                HStack(spacing: 4) {
                    if errors == 0 && warnings == 0 {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        if errors   > 0 { Label("\(errors)",   systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                        if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                }
                .font(.caption)
            }
            .help("Toggle Problems panel (⇧⌘M)")
        }
#if os(macOS)
        ToolbarItem(placement: .automatic) {
            Button(action: toggleTerminalPanel) {
                Label("Terminal", systemImage: "terminal")
            }
            .disabled(projectDirectory == nil)
            .foregroundStyle(showTerminal ? Color.accentColor : Color.primary)
            .help(showTerminal ? "Hide embedded terminal (⌃`)" : "Show embedded terminal (⌃`)")
        }
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
            Button(action: requestFinalBuild) {
                if compiler.isCompiling {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Build")
                    }
                } else {
                    Label("Build", systemImage: "hammer")
                }
            }
            .keyboardShortcut(shortcuts.combo(.build).keyboardShortcut)
            .help(compiler.isCompiling
                  ? "Stop the current compilation and restart (\(shortcuts.combo(.build).display))"
                  : "Final build: full-res images, rerun-until-stable + biber (\(shortcuts.combo(.build).display))")
        }
        ToolbarItem(placement: .automatic) {
            if compiler.previewState == .loadingImages {
                Label("Loading images…", systemImage: "photo.badge.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The draft remains usable while screen-resolution images are prepared.")
            } else if let imageError = compiler.imagePreviewError {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .help("Image preview failed; keeping the draft.\n\(imageError)")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: requestCleanBuild) {
                Label("Clean Build", systemImage: "arrow.triangle.2.circlepath")
            }
                .keyboardShortcut(shortcuts.combo(.cleanBuild).keyboardShortcut)
                .help(compiler.isCompiling
                      ? "Stop the current compilation and restart cleanly (\(shortcuts.combo(.cleanBuild).display))"
                      : "Clean build: wipe cached artifacts, then full compile (\(shortcuts.combo(.cleanBuild).display))")
        }
    }

    private func requestFinalBuild() {
        // A previously accepted clean restart is already producing the requested outcome. Treat
        // repeated button/shortcut presses as idempotent instead of showing a confirmation whose
        // confirm action would have nothing additional to do.
        guard !compiler.restartInProgress else { return }
        if compiler.isCompiling {
            showCompileRestartConfirmation = true
        } else {
            Task { await compiler.compile(source: document.source, profile: .finalCompile) }
        }
    }

    private func requestCleanBuild() {
        guard !compiler.restartInProgress else { return }
        if compiler.isCompiling {
            showCompileRestartConfirmation = true
        } else {
            Task { await compiler.cleanBuild(source: document.source) }
        }
    }
}

#if os(macOS)
import AppKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - Embedded terminal

private struct EmbeddedTerminalPanel: View {
    let directory: URL
    let isVisible: Bool
    @Binding var revision: Int
    @Binding var focusRequest: Int
    let onClose: () -> Void

    private var projectName: String {
        directory.lastPathComponent.removingPercentEncoding ?? directory.lastPathComponent
    }

    private var sessionIdentity: String {
        "\(directory.standardizedFileURL.path)#\(revision)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                Text("Terminal").fontWeight(.semibold)
                Text(projectName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    revision &+= 1
                    focusRequest &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart terminal")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close terminal")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))

            NativeTerminalView(
                configuration: NativeTerminalConfiguration(workingDirectory: directory),
                onCloseRequest: onClose,
                focusRequest: focusRequest)
                .id(sessionIdentity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 260)
        .background(Color(nsColor: .textBackgroundColor))
        // Keep the 260pt terminal subtree alive while an outer clipped frame collapses the panel.
        .frame(height: isVisible ? 260 : 0, alignment: .top)
        .clipped()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }
}

struct EmbeddedTerminalToggleKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var embeddedTerminalToggle: (() -> Void)? {
        get { self[EmbeddedTerminalToggleKey.self] }
        set { self[EmbeddedTerminalToggleKey.self] = newValue }
    }
}

// MARK: - Folder-grouped native window tabs

/// Groups document windows into native tabs by their .tex file's folder: every window gets
/// `tabbingIdentifier = "itex::<folder>"`, so opening a document from the same folder lands as a
/// tab in the existing window (adopting its exact frame so Magnet-style snaps survive); a
/// different folder opens its own window. The Welcome window has no accessor → its own tab group.
private struct WindowAccessor: NSViewRepresentable {
    let rootKey: String

    func makeCoordinator() -> Coordinator { Coordinator(rootKey: rootKey) }

    func makeNSView(context: Context) -> WindowReaderView {
        let v = WindowReaderView()
        let coord = context.coordinator
        v.onWindow = { window in coord.attach(window) }
        return v
    }
    func updateNSView(_ nsView: WindowReaderView, context: Context) {}

    final class WindowReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var fired = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window, !fired { fired = true; onWindow?(w) }
        }
    }

    final class Coordinator {
        private static let registry = NSHashTable<NSWindow>.weakObjects()
        private let rootKey: String
        init(rootKey: String) { self.rootKey = rootKey }

        private var tabID: NSWindow.TabbingIdentifier { "itex::\(rootKey)" }

        func attach(_ window: NSWindow) {
            window.tabbingMode = .preferred
            window.tabbingIdentifier = tabID
            let host = existingHost(excluding: window)
            Self.registry.add(window)
            guard let host else { return }
            let hostFrame = host.frame
            if window.tabGroup !== host.tabGroup {
                host.addTabbedWindow(window, ordered: .above)
            }
            window.setFrame(hostFrame, display: false)
            window.makeKeyAndOrderFront(nil)
            // A post-tab layout pass can nudge the group off its snap; re-assert once it settles.
            DispatchQueue.main.async { [weak host, weak window] in
                guard let host, let window else { return }
                let f = host.frame
                if window.frame != f { window.setFrame(f, display: false) }
            }
        }

        private func existingHost(excluding window: NSWindow) -> NSWindow? {
            let match: (NSWindow) -> Bool = { $0 !== window && $0.tabbingIdentifier == self.tabID }
            return Self.registry.allObjects.first(where: match) ?? NSApp.windows.first(where: match)
        }
    }
}

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
    // Extensions the app can open as documents (see CFBundleDocumentTypes: .tex + plain-text kin).
    static let openableExts: Set<String> = ["tex", "bib", "sty", "cls", "txt", "md", "log"]
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
    @State private var previewOn = false

    var body: some View {
        Group {
            if let root {
                List(selection: $selection) {
                    Section {
                        ForEach(FileEntry.children(of: root)) { entry in
                            FileRow(entry: entry, currentFile: currentFile, tree: tree)
                        }
                    } header: {
                        Text(root.lastPathComponent.removingPercentEncoding ?? root.lastPathComponent)
                            .contextMenu {
                                Button("Open in Terminal") { ExternalTerminalLauncher.open(directory: root) }
                                Divider()
                                Button("New File…") { SidebarFileOps.newFile(in: root) }
                                Button("New Folder…") { SidebarFileOps.newFolder(in: root) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: URL.self) { urls in
                    if let url = urls.first { contextMenuItems(for: url) }
                } primaryAction: { urls in
                    if let url = urls.first { activate(url) }
                }
                .onKeyPress(.return) {
                    guard let sel = selection else { return .ignored }
                    activate(sel); return .handled
                }
                .onKeyPress(.space) { previewOn.toggle(); refreshPreview(); return .handled }
                .onDeleteCommand {   // standard macOS delete hook; onKeyPress never receives ⌘-combos
                    guard let sel = selection else { return }
                    SidebarPreviewPanel.shared.hide()   // panel may be showing the file being deleted
                    SidebarFileOps.delete(sel)
                }
                .onChange(of: selection) { _, _ in refreshPreview() }
                .onDisappear { SidebarPreviewPanel.shared.hide() }
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder",
                    description: Text("Open a .tex file to browse its folder."))
            }
        }
        .onAppear { tree.watch(root); selection = currentFile }
        .onChange(of: root) { _, new in tree.watch(new) }
        .onChange(of: currentFile) { _, f in selection = f }
    }

    /// Double-click / Return: the only paths that open anything. Folders toggle disclosure,
    /// previewables open the preview panel, documents open as a tab. Arrow-key selection alone
    /// never opens or previews — that conflation was the source of the sidebar's focus bugs.
    private func activate(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()
        if isDir.boolValue {
            if SidebarExpansion.shared.expanded.contains(url) { SidebarExpansion.shared.expanded.remove(url) }
            else { SidebarExpansion.shared.expanded.insert(url) }
        } else if FileEntry.imageExts.contains(ext) {
            previewOn = true
            refreshPreview()
        } else if FileEntry.openableExts.contains(ext),
                  url.standardizedFileURL != currentFile?.standardizedFileURL {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// Preview panel follows the selection while toggled on; hides on non-previewable rows
    /// (toggle state survives, Quick Look-style).
    private func refreshPreview() {
        guard previewOn, let url = selection,
              FileEntry.imageExts.contains(url.pathExtension.lowercased()) else {
            SidebarPreviewPanel.shared.hide(); return
        }
        SidebarPreviewPanel.shared.show(url: url, in: NSApp.keyWindow)
    }

    @ViewBuilder private func contextMenuItems(for url: URL) -> some View {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            Button("Open in Terminal") { ExternalTerminalLauncher.open(directory: url) }
            Divider()
            Button("New File…") { SidebarFileOps.newFile(in: url) }
            Button("New Folder…") { SidebarFileOps.newFolder(in: url) }
            Divider()
        }
        Button("Rename…") { SidebarFileOps.promptRename(url) }
        Button("Delete") { SidebarFileOps.delete(url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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

    @State private var dropTargeted = false

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(children) { FileRow(entry: $0, currentFile: currentFile, tree: tree) }
            } label: {
                Label(entry.name, systemImage: "folder").lineLimit(1)
                    .background(dropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
                    .onDrag { NSItemProvider(object: entry.url as NSURL) }
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
            }
            .tag(entry.url)
            .onAppear { reloadChildrenIfExpanded() }
            .onChange(of: expansion.expanded) { _, _ in reloadChildrenIfExpanded() }
            .onChange(of: tree.version) { _, _ in reloadChildrenIfExpanded() }
        } else {
            Label {
                Text(entry.name).lineLimit(1)
            } icon: {
                Image(systemName: entry.isImage ? "photo" : entry.isTex ? "doc.text" : "doc")
                    .foregroundStyle(entry.isTex ? Color.accentColor : Color.secondary)
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .tag(entry.url)
            .onDrag { NSItemProvider(object: entry.url as NSURL) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { SidebarFileOps.move(url, into: entry.url) }
            }
        }
        return handled
    }
}

// MARK: - Sidebar file operations (FileManager-based; FSEvents refreshes the tree)

private enum SidebarFileOps {
    static func newFile(in dir: URL) {
        let url = uniqueURL(in: dir, base: "Untitled", ext: "tex")
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            promptRename(url)
        } catch { warn("Couldn't create the file.", error) }
    }

    static func newFolder(in dir: URL) {
        let url = uniqueURL(in: dir, base: "Untitled Folder", ext: "")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            promptRename(url)
        } catch { warn("Couldn't create the folder.", error) }
    }

    static func promptRename(_ url: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Rename"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = url.lastPathComponent
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != url.lastPathComponent else { return }
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                NSSound.beep(); warn("An item named “\(name)” already exists."); return
            }
            do { try FileManager.default.moveItem(at: url, to: dest) }
            catch { NSSound.beep(); warn("Couldn't rename the item.", error) }
        }
    }

    static func delete(_ url: URL) {
        if openConflict(url) { blocked(url, verb: "deleted"); return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
            alert.informativeText = "You can restore it from the Trash later."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { NSSound.beep(); warn("Couldn't move the item to the Trash.", error) }
        }
    }

    static func move(_ src: URL, into folder: URL) {
        let s = src.standardizedFileURL, d = folder.standardizedFileURL
        guard d != s, !d.path.hasPrefix(s.path + "/") else { NSSound.beep(); return }   // no folder-into-descendant
        guard s.deletingLastPathComponent() != d else { return }                        // already in this folder
        let dest = d.appendingPathComponent(s.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            NSSound.beep()
            warn("An item named “\(s.lastPathComponent)” already exists in “\(d.lastPathComponent)”.")
            return
        }
        do { try FileManager.default.moveItem(at: s, to: dest) }
        catch { NSSound.beep(); warn("Couldn't move the item.", error) }
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? base : "\(base) \(n)"
            return dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        var n = 1, url = candidate(n)
        while fm.fileExists(atPath: url.path) { n += 1; url = candidate(n) }
        return url
    }

    /// True when `url` is a file open in any window, or a folder that contains one — trashing it
    /// would delete a document out from under its window, so delete is blocked in that case.
    /// (Rename/move are allowed: NSDocument follows moves on disk and keeps saving correctly.)
    private static func openConflict(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.contains { doc in
            guard let f = doc.fileURL?.standardizedFileURL.path else { return false }
            return f == p || f.hasPrefix(p + "/")
        }
    }

    private static func blocked(_ url: URL, verb: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(url.lastPathComponent)” is open and can't be \(verb)."
            alert.informativeText = "Close its window first."
            alert.runModal()
        }
    }

    private static func warn(_ message: String, _ error: Error? = nil) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            if let error { alert.informativeText = error.localizedDescription }
            alert.runModal()
        }
    }
}

// MARK: - Sidebar image/PDF preview panel

/// Quick Look-style preview for the sidebar's selected image/PDF, toggled with Space.
/// A non-activating child panel (never key — the List keeps keyboard focus, unlike an
/// NSPopover/.popover which steals it) anchored beside the selected row.
/// ponytail: anchored at show-time row rect — scrolling the list doesn't move it; it re-anchors
/// on the next selection change. Track scroll notifications if that ever matters.
@MainActor
final class SidebarPreviewPanel {
    static let shared = SidebarPreviewPanel()
    private var panel: NSPanel?

    func show(url: URL, in window: NSWindow?) {
        guard let window, let img = NSImage(contentsOf: url),
              let table = (window.firstResponder as? NSTableView)
                ?? firstTable(in: window.contentView), table.selectedRow >= 0
        else { hide(); return }

        // Selected row's frame in screen coords; panel sits to its right.
        let rowInWindow = table.convert(table.rect(ofRow: table.selectedRow), to: nil)
        let rowOnScreen = window.convertToScreen(rowInWindow)

        let maxDim: CGFloat = 360
        let scale = min(1, maxDim / max(img.size.width, img.size.height, 1))
        let size = NSSize(width: max(img.size.width * scale, 40), height: max(img.size.height * scale, 40))

        let p = panel ?? makePanel()
        (p.contentView as? NSImageView)?.image = img
        var origin = NSPoint(x: rowOnScreen.maxX + 8, y: rowOnScreen.midY - size.height / 2)
        if let vf = window.screen?.visibleFrame {
            origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
            origin.x = min(origin.x, vf.maxX - size.width)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        if p.parent == nil { window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .windowBackgroundColor
        p.isExcludedFromWindowsMenu = true
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        p.contentView = iv
        panel = p
        return p
    }

    private func firstTable(in root: NSView?) -> NSTableView? {
        guard let root else { return nil }
        if let t = root as? NSTableView { return t }
        for sub in root.subviews { if let t = firstTable(in: sub) { return t } }
        return nil
    }
}
#endif
