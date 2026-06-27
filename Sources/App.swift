import SwiftUI

@main
struct iTexApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
#if os(macOS)
        // First scene = shown at launch → welcome, no untitled document flash.
        Window("Welcome to iTex", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
#endif
        DocumentGroup(newDocument: LaTeXDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
#if os(macOS)
        Settings { ShortcutSettingsView() }   // ⌘, opens this automatically
#endif
    }
}
