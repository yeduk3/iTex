import SwiftUI

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
            // ⌘N opens a fresh launch screen (replaces DocumentGroup's "New Document").
            CommandGroup(replacing: .newItem) { NewWelcomeWindowButton() }
        }
#endif
        DocumentGroup(newDocument: LaTeXDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
#if os(macOS)
        Settings { ShortcutSettingsView() }   // ⌘, opens this automatically
#endif
    }
}

#if os(macOS)
/// File ▸ New Window (⌘N): opens another welcome/launch window. A View so it can read openWindow.
private struct NewWelcomeWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Window") { openWindow(id: "welcome") }
            .keyboardShortcut("n", modifiers: .command)
    }
}
#endif
