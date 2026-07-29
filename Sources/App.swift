import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct iTexApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
#if os(macOS)
        // First scene = shown at launch → welcome, no untitled document flash. WindowGroup (not
        // Window) so ⌘N can spawn additional welcome windows.
        WindowGroup("Welcome to iTex", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) { WorkspaceFileCommands() }
            CommandGroup(replacing: .saveItem) { WorkspaceSaveCommands() }
            // File ▸ Open Project in Terminal, scoped to the focused saved document.
            CommandGroup(after: .newItem) { OpenProjectInTerminalCommand() }
            // View ▸ font zoom (⌘+/⌘-/⌘0), applied live to every open editor.
            CommandGroup(after: .toolbar) { FontSizeCommands() }
            // View ▸ Show Problems (⇧⌘M), toggling the focused window's diagnostics panel.
            CommandGroup(after: .toolbar) { ProblemsCommands() }
            // View ▸ Toggle Terminal, routed to the focused saved document window.
            CommandGroup(after: .toolbar) { EmbeddedTerminalCommands() }
            // Edit ▸ Find (⌘F/⌘G/⇧⌘G/⌘⌥F), routed to the focused window's find controller.
            CommandGroup(after: .textEditing) { FindCommands() }
            // Window ▸ tab navigation (⌘⌥←/→), routed to the focused project's editor tabs.
            CommandGroup(after: .windowArrangement) { TabCommands() }
            // Replace the default Print (⌘P) — a LaTeX editor doesn't print source — with the
            // quick-open palette on the same shortcut, routed to the focused window.
            CommandGroup(replacing: .printItem) { QuickOpenCommand() }
        }

        WindowGroup("iTex Project", for: ProjectLaunch.self) { launch in
            if let launch = launch.wrappedValue {
                ProjectWorkspaceView(initialURL: launch.fileURL)
            } else {
                ContentUnavailableView("No Project", systemImage: "folder")
            }
        }
        .defaultSize(width: 1200, height: 780)

        Settings { ShortcutSettingsView() }   // ⌘, opens this automatically
#else
        DocumentGroup(newDocument: LaTeXDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
#endif
    }
}

#if os(macOS)
private struct WorkspaceFileCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Document") {
            WorkspaceLauncher.newDocument { openWindow(value: $0) }
        }
            .keyboardShortcut("n", modifiers: .command)
        Button("Open…") {
            WorkspaceLauncher.openDocument { openWindow(value: $0) }
        }
            .keyboardShortcut("o", modifiers: .command)
        Divider()
        Button("New Welcome Window") { openWindow(id: "welcome") }
    }
}

private struct WorkspaceSaveCommands: View {
    @FocusedValue(\.workspaceSaveAction) private var save: (() -> Void)?
    @FocusedValue(\.workspaceSaveAllAction) private var saveAll: (() -> Void)?

    var body: some View {
        Button("Save") { save?() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(save == nil)
        Button("Save All") { saveAll?() }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(saveAll == nil)
    }
}

/// File-menu terminal launcher; disabled for welcome and unsaved document windows.
private struct OpenProjectInTerminalCommand: View {
    @FocusedValue(\.projectDirectory) private var directory: URL?
    var body: some View {
        Button("Open Project in Terminal") {
            if let directory { ExternalTerminalLauncher.open(directory: directory) }
        }
        .disabled(directory == nil)
    }
}

/// View-menu editor font zoom. ⌘+ bigger, ⌘- smaller, ⌘0 actual size. (⌘+ is produced by ⌘⇧=.)
private struct FontSizeCommands: View {
    @ObservedObject private var font = FontScale.shared
    var body: some View {
        Button("Increase Font Size") { font.zoomIn() }
            .keyboardShortcut("+", modifiers: .command)
        Button("Decrease Font Size") { font.zoomOut() }
            .keyboardShortcut("-", modifiers: .command)
        Button("Actual Size") { font.reset() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(font.scale == 1.0)
    }
}

/// Window-menu project editor navigation: the shared PDF viewer is not part of this tab switch.
private struct TabCommands: View {
    @FocusedValue(\.workspacePreviousTabAction) private var previous: (() -> Void)?
    @FocusedValue(\.workspaceNextTabAction) private var next: (() -> Void)?

    var body: some View {
        Divider()
        Button("Show Previous Editor") { previous?() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(previous == nil)
        Button("Show Next Editor") { next?() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(next == nil)
    }
}

/// Edit-menu Find items wired to the focused window's find controller; no-op with no editor window.
private struct FindCommands: View {
    @FocusedValue(\.findController) private var find: FindController?
    var body: some View {
        Button("Find…") { find?.show() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(find == nil)
        Button("Find and Replace…") { find?.toggleReplace() }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(find == nil)
        Button("Find Next") { find?.next() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(find == nil)
        Button("Find Previous") { find?.prev() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find == nil)
    }
}

/// View-menu Show Problems (⇧⌘M) toggling the focused window's diagnostics panel.
private struct ProblemsCommands: View {
    @FocusedValue(\.problemsToggle) private var toggle: (() -> Void)?
    var body: some View {
        Button("Show Problems") { toggle?() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(toggle == nil)
    }
}

/// View-menu embedded terminal visibility toggle. It preserves a hidden session.
private struct EmbeddedTerminalCommands: View {
    @FocusedValue(\.embeddedTerminalToggle) private var toggle: (() -> Void)?
    var body: some View {
        Button("Toggle Terminal") { toggle?() }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(toggle == nil)
    }
}

/// File-menu Quick Open… (⌘P) raising the focused window's palette; disabled with no editor window.
private struct QuickOpenCommand: View {
    @FocusedValue(\.quickOpenAction) private var action: (() -> Void)?
    var body: some View {
        Button("Quick Open…") { action?() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(action == nil)
    }
}

private struct FindControllerKey: FocusedValueKey { typealias Value = FindController }
extension FocusedValues {
    var findController: FindController? {
        get { self[FindControllerKey.self] }
        set { self[FindControllerKey.self] = newValue }
    }
}
#endif
