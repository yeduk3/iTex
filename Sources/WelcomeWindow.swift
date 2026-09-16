#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Launch experience: the welcome window is the app's FIRST scene (see iTexApp.body), so a plain
/// launch lands here with no untitled document flashing. This delegate stops NSDocumentController
/// from auto-opening an untitled file on launch / reopen, and gates quit on unsaved project editors.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never restore the previous session's document windows — a plain launch shows welcome only.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q with unsaved editors: each project window asks once; any Cancel keeps the app running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceWindowCloseGuard.terminateReply(for: WorkspaceWindowCloseGuard.live)
    }
}

enum WorkspaceLauncher {
    static func newDocument(open: @escaping (ProjectLaunch) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.latexSource]
        panel.nameFieldStringValue = "Untitled.tex"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(defaultLaTeXSource.utf8).write(to: url, options: .atomic)
                open(ProjectLaunch(fileURL: url))
            } catch {
                present(error: error)
            }
        }
    }

    static func openDocument(open: @escaping (ProjectLaunch) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.latexSource, .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            open(ProjectLaunch(fileURL: url))
        }
    }

    private static func present(error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

/// Welcome scene content: New / Open / recent files. Each choice launches one project window;
/// included sources subsequently open as internal editor tabs in that same window.
struct WelcomeView: View {
    @Environment(\.openWindow)    private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var recents: [URL] { NSDocumentController.shared.recentDocumentURLs }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "function").font(.system(size: 52)).foregroundStyle(.tint)
                Text("iTex").font(.largeTitle.bold())
                Text("LaTeX editor").foregroundStyle(.secondary)
                Spacer()
                Button(action: newDoc)    { Label("New Document", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                Button(action: openPanel) { Label("Open…",        systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }
            }
            .controlSize(.large)
            .padding(28)
            .frame(width: 250, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").font(.headline).padding(.horizontal, 16).padding(.top, 16)
                if recents.isEmpty {
                    Spacer()
                    Text("No recent files").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List(recents, id: \.self) { url in
                        Button { open(url) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onOpenURL { open($0) }
    }

    private func newDoc() {
        WorkspaceLauncher.newDocument { launch in
            openWindow(value: launch)
            dismissWindow()
        }
    }

    private func open(_ url: URL) {
        openWindow(value: ProjectLaunch(fileURL: url))
        dismissWindow()
    }

    private func openPanel() {
        WorkspaceLauncher.openDocument { launch in
            openWindow(value: launch)
            dismissWindow()
        }
    }
}
#endif
