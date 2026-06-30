#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Launch experience: the welcome window is the app's FIRST scene (see iTexApp.body), so a plain
/// launch lands here with no untitled document flashing. This delegate only stops NSDocumentController
/// from auto-opening an untitled file on launch / reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never restore the previous session's document windows — a plain launch shows welcome only.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

/// Welcome scene content: New / Open / recent files. Hosted by a SwiftUI `Window` scene so it shows
/// natively at launch; document actions go through the standard DocumentGroup environment actions.
struct WelcomeView: View {
    @Environment(\.newDocument)   private var newDocument
    @Environment(\.openDocument)  private var openDocument
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
    }

    private func newDoc() {
        newDocument(LaTeXDocument())
        dismissWindow()   // this welcome window (multiple may be open)
    }

    private func open(_ url: URL) {
        Task { try? await openDocument(at: url); dismissWindow() }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.latexSource, .plainText]
        panel.begin { resp in
            if resp == .OK, let url = panel.url { open(url) }
        }
    }
}
#endif
