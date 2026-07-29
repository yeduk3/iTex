#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// The value passed to the project scene. A stable UUID lets the user intentionally open a
/// second window for the same project while every file inside one window remains an editor tab.
struct ProjectLaunch: Codable, Hashable {
    let id: UUID
    let path: String

    init(fileURL: URL, id: UUID = UUID()) {
        self.id = id
        path = fileURL.standardizedFileURL.path
    }

    var fileURL: URL { URL(filePath: path).standardizedFileURL }
}

@MainActor
@Observable
final class WorkspaceEditorTab: Identifiable {
    let id = UUID()
    let url: URL
    var source: String
    private(set) var savedSource: String

    init(url: URL, source: String) {
        self.url = url.standardizedFileURL
        self.source = source
        savedSource = source
    }

    var isDirty: Bool { source != savedSource }
    func markSaved() { savedSource = source }
}

/// One project window owns this object. The compiler, LSP and PDF URL live here—not in an
/// editor tab—so selecting another included source file cannot create or refresh a PDF viewer.
@MainActor
@Observable
final class ProjectWorkspace {
    private(set) var tabs: [WorkspaceEditorTab] = []
    var activeTabID: UUID?
    private(set) var projectContext: LaTeXProjectContext
    var lastError: String?

    let compiler = LaTeXCompiler()
    let linter = ChkTexLinter()
    let texLabClient = TexLabClient()
    let diagnostics = DiagnosticsStore()

    private var started = false
    private let tracksRecentDocuments: Bool

    init(initialURL: URL, tracksRecentDocuments: Bool = true) {
        self.tracksRecentDocuments = tracksRecentDocuments
        let url = initialURL.standardizedFileURL
        projectContext = LaTeXProjectResolver.resolve(url)
        do {
            let source = try Self.read(url)
            let tab = WorkspaceEditorTab(url: url, source: source)
            tabs = [tab]
            activeTabID = tab.id
        } catch {
            let tab = WorkspaceEditorTab(url: url, source: "")
            tabs = [tab]
            activeTabID = tab.id
            lastError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
        compiler.configureProject(context(for: url))
        if tracksRecentDocuments {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    var activeTab: WorkspaceEditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeFileURL: URL? { activeTab?.url }
    var projectDirectory: URL { projectContext.projectDirectory }
    var projectName: String {
        projectDirectory.lastPathComponent.removingPercentEncoding
            ?? projectDirectory.lastPathComponent
    }
    var hasDirtyTabs: Bool { tabs.contains(where: \.isDirty) }
    var windowTitle: String {
        guard let activeTab else { return projectName }
        return "\(activeTab.url.lastPathComponent) — \(projectName)"
    }

    func start() async {
        guard !started else { return }
        started = true

        compiler.onNavigateToSource = { [weak self] url, line in
            self?.openTab(url, line: line)
        }
        compiler.configureProject(context(for: activeFileURL ?? projectContext.currentFile))
        diagnostics.setBuild(compiler.buildDiagnostics)

        texLabClient.onDiagnostics = { [weak self] in self?.diagnostics.setLSP($0) }
        linter.onResults = { [weak self] warnings in
            guard let self else { return }
            let file = self.activeFileURL
            self.diagnostics.setChkTex(warnings.map {
                Diagnostic(
                    source: .chktex,
                    severity: $0.isError ? .error : .warning,
                    file: file,
                    line: $0.line,
                    message: $0.message
                )
            })
        }

        texLabClient.start(workspaceURL: projectDirectory)
        for _ in 0..<30 where !texLabClient.isReady {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let activeTab, texLabClient.isReady {
            texLabClient.openDocument(url: activeTab.url, text: activeTab.source)
        }

        if let activeTab {
            await compiler.compile(source: activeTab.source)
            await linter.lint(fileURL: activeTab.url)
        }
    }

    func openTab(_ url: URL, line: Int? = nil) {
        let normalized = url.standardizedFileURL
        if let existing = tabs.first(where: { $0.url == normalized }) {
            activate(existing.id, line: line)
            return
        }
        do {
            let tab = WorkspaceEditorTab(url: normalized, source: try Self.read(normalized))
            tabs.append(tab)
            activate(tab.id, line: line)
            if tracksRecentDocuments {
                NSDocumentController.shared.noteNewRecentDocumentURL(normalized)
            }
        } catch {
            lastError = "Could not open \(normalized.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func activate(_ id: UUID, line: Int? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        compiler.configureProject(context(for: tab.url))
        if texLabClient.isReady {
            texLabClient.openDocument(url: tab.url, text: tab.source)
        }
        if let line {
            PendingJump.shared.set(tab.url, line: line)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .iTexJumpToLine,
                    object: nil,
                    userInfo: ["url": tab.url, "line": line]
                )
            }
        }
        Task { await linter.lint(fileURL: tab.url) }
    }

    func selectPreviousTab() {
        selectTab(offset: -1)
    }

    func selectNextTab() {
        selectTab(offset: 1)
    }

    private func selectTab(offset: Int) {
        guard !tabs.isEmpty,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func saveActiveAndCompile() async {
        guard let activeTab else { return }
        do {
            try save(activeTab)
            refreshProjectContext()
            compiler.configureProject(context(for: activeTab.url))
            await compiler.compile(source: activeTab.source, profile: .fastPreview)
            await linter.lint(fileURL: activeTab.url)
        } catch {
            lastError = "Could not save \(activeTab.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveAll() throws {
        for tab in tabs where tab.isDirty {
            try save(tab)
        }
        refreshProjectContext()
    }

    func finalBuild() async {
        guard let activeTab else { return }
        do {
            try saveAll()
            compiler.configureProject(context(for: activeTab.url))
            await compiler.compile(source: activeTab.source, profile: .finalCompile)
        } catch {
            lastError = "Could not save project files: \(error.localizedDescription)"
        }
    }

    func cleanBuild() async {
        guard let activeTab else { return }
        do {
            try saveAll()
            compiler.configureProject(context(for: activeTab.url))
            await compiler.cleanBuild(source: activeTab.source)
        } catch {
            lastError = "Could not save project files: \(error.localizedDescription)"
        }
    }

    func forceCleanRestart() async {
        guard let activeTab else { return }
        do {
            try saveAll()
            compiler.configureProject(context(for: activeTab.url))
            await compiler.forceCleanRestart(source: activeTab.source)
        } catch {
            lastError = "Could not save project files: \(error.localizedDescription)"
        }
    }

    func requestCloseTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(tab.url.lastPathComponent)?"
            alert.informativeText = "Your changes will be lost if you close this editor without saving."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do { try save(tab) }
                catch {
                    lastError = "Could not save \(tab.url.lastPathComponent): \(error.localizedDescription)"
                    return
                }
            case .alertThirdButtonReturn:
                break
            default:
                return
            }
        }

        let wasActive = activeTabID == id
        tabs.remove(at: index)
        if wasActive {
            if tabs.isEmpty {
                activeTabID = nil
                compiler.fileURL = nil
                compiler.configureProject(nil)
            } else {
                activate(tabs[min(index, tabs.count - 1)].id)
            }
        }
    }

    func shutdown() {
        texLabClient.stop()
        Task { await compiler.shutdownWarm() }
    }

    private func save(_ tab: WorkspaceEditorTab) throws {
        try Data(tab.source.utf8).write(to: tab.url, options: .atomic)
        tab.markSaved()
    }

    private func refreshProjectContext() {
        projectContext = LaTeXProjectResolver.resolve(projectContext.mainFile)
    }

    /// Preserve the owning main document when a .bib/.sty or a not-yet-included .tex file is
    /// opened from this project's sidebar. Only the current editor changes.
    private func context(for currentFile: URL) -> LaTeXProjectContext {
        LaTeXProjectContext(
            currentFile: currentFile.standardizedFileURL,
            mainFile: projectContext.mainFile,
            projectDirectory: projectContext.projectDirectory,
            rootSource: projectContext.rootSource,
            includedFiles: projectContext.includedFiles
        )
    }

    private static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return source
    }
}

struct ProjectWorkspaceView: View {
    @State private var workspace: ProjectWorkspace
    @State private var shortcuts = ShortcutStore.shared
    @StateObject private var quickOpen = QuickOpenController()
    @State private var showProblems = false
    @State private var showCompileRestartConfirmation = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var terminalSessionActive = false
    @State private var terminalWorkingDirectory: URL?
    @State private var showTerminal = false
    @State private var terminalRevision = 0
    @State private var terminalFocusRequest = 0
    @AppStorage("previewSplitVertical") private var verticalSplit = false
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("splitFractionH") private var splitFractionH = 0.5
    @AppStorage("splitFractionV") private var splitFractionV = 0.5

    init(initialURL: URL) {
        _workspace = State(initialValue: ProjectWorkspace(initialURL: initialURL))
    }

    var body: some View {
        focusedContent
    }

    private var baseLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                root: workspace.projectDirectory,
                currentFile: workspace.activeFileURL,
                onOpen: { workspace.openTab($0) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                EditorTabStrip(workspace: workspace)
                editorPreviewSplit.frame(minHeight: 180)
                if showProblems {
                    ProblemsPanel(store: workspace.diagnostics, onJump: handleProblemJump)
                }
                if terminalSessionActive, let directory = terminalWorkingDirectory {
                    EmbeddedTerminalPanel(
                        directory: directory,
                        isVisible: showTerminal,
                        revision: $terminalRevision,
                        focusRequest: $terminalFocusRequest,
                        onClose: closeTerminalSession
                    )
                }
            }
            .frame(minWidth: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: minimumWindowHeight)
        .toolbar { toolbarContent }
        .background {
            Button("Toggle Sidebar", action: toggleSidebar)
                .keyboardShortcut(shortcuts.combo(.toggleSidebar).keyboardShortcut)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .background(
            WorkspaceWindowAccessor(
                title: workspace.windowTitle,
                representedURL: workspace.activeFileURL,
                isDocumentEdited: workspace.hasDirtyTabs
            )
        )
    }

    private var lifecycleContent: some View {
        baseLayout
        .onAppear { columnVisibility = showSidebar ? .all : .doubleColumn }
        .onChange(of: columnVisibility) { _, visibility in
            showSidebar = visibility != .detailOnly
            if visibility == .detailOnly { SidebarPreviewPanel.shared.hide() }
        }
        .onChange(of: workspace.compiler.buildDiagnostics) { _, diagnostics in
            workspace.diagnostics.setBuild(diagnostics)
            if !diagnostics.isEmpty { showProblems = true }
        }
        .task { await workspace.start() }
        .onDisappear { workspace.shutdown() }
    }

    private var presentedContent: some View {
        lifecycleContent
        .sheet(
            isPresented: Binding(
                get: { quickOpen.isVisible },
                set: { if !$0 { quickOpen.hide() } }
            )
        ) {
            QuickOpenPalette(controller: quickOpen, onOpen: handleQuickOpen)
        }
        .alert("Restart Compilation?", isPresented: $showCompileRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Stop & Restart", role: .destructive) {
                Task { await workspace.forceCleanRestart() }
            }
        } message: {
            Text("A compilation is still running. Stop it and start a clean build from the beginning?")
        }
        .alert(
            "Project Error",
            isPresented: Binding(
                get: { workspace.lastError != nil },
                set: { if !$0 { workspace.lastError = nil } }
            )
        ) {
            Button("OK") { workspace.lastError = nil }
        } message: {
            Text(workspace.lastError ?? "")
        }
    }

    private var focusedContent: some View {
        presentedContent
        .focusedSceneValue(\.quickOpenAction, { quickOpen.show(root: workspace.projectDirectory) })
        .focusedSceneValue(\.problemsToggle, { showProblems.toggle() })
        .focusedSceneValue(\.projectDirectory, workspace.projectDirectory)
        .focusedSceneValue(\.embeddedTerminalToggle, toggleTerminalPanel)
        .focusedSceneValue(\.workspaceSaveAction, {
            Task { await workspace.saveActiveAndCompile() }
        })
        .focusedSceneValue(\.workspaceSaveAllAction, {
            Task {
                do { try workspace.saveAll() }
                catch { workspace.lastError = "Could not save project files: \(error.localizedDescription)" }
            }
        })
        .focusedSceneValue(\.workspacePreviousTabAction, workspace.selectPreviousTab)
        .focusedSceneValue(\.workspaceNextTabAction, workspace.selectNextTab)
    }

    private var editorPreviewSplit: some View {
        DraggableSplit(
            vertical: verticalSplit,
            fraction: verticalSplit ? $splitFractionV : $splitFractionH
        ) {
            WorkspaceEditors(workspace: workspace)
        } second: {
            // Exactly one viewer exists for the lifetime of the project window.
            PDFPreviewView(
                compiler: workspace.compiler,
                repaintToken: workspace.activeTabID.map(AnyHashable.init)
            )
        }
    }

    private var minimumWindowHeight: CGFloat {
        showTerminal && showProblems ? 650 : 500
    }

    private func handleQuickOpen(_ url: URL, line: Int?) {
        quickOpen.hide()
        if line != nil || QuickOpenController.openableExts.contains(url.pathExtension.lowercased()) {
            workspace.openTab(url, line: line)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func handleProblemJump(_ diagnostic: Diagnostic) {
        guard let url = diagnostic.file ?? workspace.activeFileURL else { return }
        workspace.openTab(url, line: diagnostic.line)
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
        }
    }

    private func toggleTerminalPanel() {
        if !terminalSessionActive {
            terminalWorkingDirectory = workspace.projectDirectory
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
            window.makeFirstResponder(nil)
        }
    }

    private static func firstVisibleEditor(in view: NSView?) -> LaTeXTextView? {
        guard let view else { return nil }
        if let editor = view as? LaTeXTextView, !editor.isHiddenOrHasHiddenAncestor {
            return editor
        }
        for child in view.subviews {
            if let editor = firstVisibleEditor(in: child) { return editor }
        }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            let errors = workspace.diagnostics.count(.error)
            let warnings = workspace.diagnostics.count(.warning)
            Button { showProblems.toggle() } label: {
                HStack(spacing: 4) {
                    if errors == 0 && warnings == 0 {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        if errors > 0 {
                            Label("\(errors)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        if warnings > 0 {
                            Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption)
            }
            .help("Toggle Problems panel (⇧⌘M)")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: toggleTerminalPanel) {
                Label("Terminal", systemImage: "terminal")
            }
            .foregroundStyle(showTerminal ? Color.accentColor : Color.primary)
            .help(showTerminal ? "Hide embedded terminal (⌃`)" : "Show embedded terminal (⌃`)")
        }
        ToolbarItem(placement: .automatic) {
            Button { Task { await workspace.compiler.forwardSearch() } } label: {
                Label("Sync", systemImage: "scope")
            }
            .keyboardShortcut(shortcuts.combo(.forwardSync).keyboardShortcut)
            .help("SyncTeX: jump to the cursor in the shared project PDF")
        }
        ToolbarItem(placement: .automatic) {
            Button { workspace.compiler.scrollSyncEnabled.toggle() } label: {
                Label(
                    "Scroll Sync",
                    systemImage: workspace.compiler.scrollSyncEnabled
                        ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
                )
            }
            .keyboardShortcut(shortcuts.combo(.scrollSyncToggle).keyboardShortcut)
            .foregroundStyle(workspace.compiler.scrollSyncEnabled ? Color.accentColor : Color.primary)
        }
        ToolbarItem(placement: .automatic) {
            Button(action: requestFinalBuild) {
                if workspace.compiler.isCompiling {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Build")
                    }
                } else {
                    Label("Build", systemImage: "hammer")
                }
            }
            .keyboardShortcut(shortcuts.combo(.build).keyboardShortcut)
        }
        ToolbarItem(placement: .automatic) {
            if workspace.compiler.previewState == .loadingImages {
                Label("Loading images…", systemImage: "photo.badge.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let imageError = workspace.compiler.imagePreviewError {
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
        }
    }

    private func requestFinalBuild() {
        guard !workspace.compiler.restartInProgress else { return }
        if workspace.compiler.isCompiling {
            showCompileRestartConfirmation = true
        } else {
            Task { await workspace.finalBuild() }
        }
    }

    private func requestCleanBuild() {
        guard !workspace.compiler.restartInProgress else { return }
        if workspace.compiler.isCompiling {
            showCompileRestartConfirmation = true
        } else {
            Task { await workspace.cleanBuild() }
        }
    }
}

private struct WorkspaceEditors: View {
    let workspace: ProjectWorkspace

    var body: some View {
        ZStack {
            ForEach(workspace.tabs) { tab in
                let active = tab.id == workspace.activeTabID
                EditorView(
                    source: Binding(
                        get: { tab.source },
                        set: { tab.source = $0 }
                    ),
                    compiler: workspace.compiler,
                    linter: workspace.linter,
                    texLabClient: active ? workspace.texLabClient : nil,
                    documentURL: tab.url,
                    isActive: active
                )
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .accessibilityHidden(!active)
                .zIndex(active ? 1 : 0)
            }

            if workspace.tabs.isEmpty {
                ContentUnavailableView(
                    "No Open Editors",
                    systemImage: "doc.text",
                    description: Text("Open a source file from the sidebar.")
                )
            }
        }
    }
}

private struct EditorTabStrip: View {
    let workspace: ProjectWorkspace

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs) { tab in
                    HStack(spacing: 6) {
                        Button {
                            workspace.activate(tab.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(tab.url.lastPathComponent)
                                    .lineLimit(1)
                                if tab.isDirty {
                                    Circle()
                                        .fill(Color.secondary)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            workspace.requestCloseTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.borderless)
                        .help("Close Editor")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .frame(height: 30)
                    .background(
                        tab.id == workspace.activeTabID
                            ? Color(nsColor: .textBackgroundColor)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    Divider()
                }
                Spacer(minLength: 0)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .frame(height: 31)
    }
}

private struct WorkspaceWindowAccessor: NSViewRepresentable {
    let title: String
    let representedURL: URL?
    let isDocumentEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.title = title
            window.representedURL = representedURL
            window.isDocumentEdited = isDocumentEdited
            window.tabbingMode = .disallowed
        }
    }
}

struct WorkspaceSaveActionKey: FocusedValueKey { typealias Value = () -> Void }
struct WorkspaceSaveAllActionKey: FocusedValueKey { typealias Value = () -> Void }
struct WorkspacePreviousTabActionKey: FocusedValueKey { typealias Value = () -> Void }
struct WorkspaceNextTabActionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var workspaceSaveAction: (() -> Void)? {
        get { self[WorkspaceSaveActionKey.self] }
        set { self[WorkspaceSaveActionKey.self] = newValue }
    }
    var workspaceSaveAllAction: (() -> Void)? {
        get { self[WorkspaceSaveAllActionKey.self] }
        set { self[WorkspaceSaveAllActionKey.self] = newValue }
    }
    var workspacePreviousTabAction: (() -> Void)? {
        get { self[WorkspacePreviousTabActionKey.self] }
        set { self[WorkspacePreviousTabActionKey.self] = newValue }
    }
    var workspaceNextTabAction: (() -> Void)? {
        get { self[WorkspaceNextTabActionKey.self] }
        set { self[WorkspaceNextTabActionKey.self] = newValue }
    }
}
#endif
