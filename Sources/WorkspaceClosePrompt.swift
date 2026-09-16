#if os(macOS)
import AppKit
import ObjectiveC

/// The answer to closing a project window, or quitting, with unsaved editors.
enum UnsavedChangesChoice {
    case saveAll, cancel, discard
}

enum UnsavedChangesAlert {
    /// Default prompt, styled like the per-editor close alert.
    @MainActor
    static func run(_ dirtyTabs: [WorkspaceEditorTab]) -> UnsavedChangesChoice {
        let names = dirtyTabs.map(\.url.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "Save changes to \(names[0])?"
            : "Save changes to \(names.count) files?"
        let warning = "Your changes will be lost if you don’t save them."
        alert.informativeText = names.count == 1
            ? warning
            : names.joined(separator: "\n") + "\n\n" + warning
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .saveAll
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

extension ProjectWorkspace {
    /// Window close / app quit gate. True lets the close proceed: nothing unsaved, the user chose
    /// Don't Save, or Save All succeeded. A failed save reports `lastError` and keeps the window.
    func confirmCloseWithUnsavedChanges() -> Bool {
        let dirty = tabs.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        switch resolveUnsavedChanges(dirty) {
        case .cancel:
            return false
        case .discard:
            return true
        case .saveAll:
            do {
                try saveAll()
                return true
            } catch {
                lastError = "Could not save project files: \(error.localizedDescription)"
                return false
            }
        }
    }
}

/// SwiftUI owns a project window's delegate (and `NSWindow.delegate` is weak). This proxy sits in
/// front of it: `windowShouldClose` asks the workspace first; every other delegate message is
/// forwarded to SwiftUI's delegate unchanged. The window retains the proxy; the proxy holds the
/// window, workspace and SwiftUI's delegate weakly.
final class WorkspaceWindowCloseGuard: NSObject, NSWindowDelegate {
    private(set) weak var workspace: ProjectWorkspace?
    private(set) weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private var isClosed = false
    /// Unsaved edits the user already answered for during ⌘Q, so a close AppKit/SwiftUI sends
    /// while terminating doesn't ask a second time. Consumed by the next `windowShouldClose`.
    private var confirmedForQuit: [UUID: String]?

    private static var associationKey: UInt8 = 0
    private static let registry = NSHashTable<WorkspaceWindowCloseGuard>.weakObjects()

    /// Project windows still open.
    static var live: [WorkspaceWindowCloseGuard] {
        registry.allObjects.filter { $0.window != nil && !$0.isClosed && $0.workspace != nil }
    }

    /// Idempotent: one proxy per window; re-fronts SwiftUI's delegate if SwiftUI replaced ours.
    @MainActor
    @discardableResult
    static func install(on window: NSWindow, workspace: ProjectWorkspace) -> WorkspaceWindowCloseGuard {
        let proxy: WorkspaceWindowCloseGuard
        if let existing = objc_getAssociatedObject(window, &associationKey) as? WorkspaceWindowCloseGuard {
            proxy = existing
        } else {
            proxy = WorkspaceWindowCloseGuard()
            proxy.window = window
            objc_setAssociatedObject(window, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            registry.add(proxy)
        }
        proxy.workspace = workspace
        if window.delegate !== proxy {
            proxy.original = window.delegate
            window.delegate = proxy
        }
        return proxy
    }

    /// ⌘Q: every open project window with unsaved editors asks once (fronted first). Any Cancel or
    /// failed save keeps the app running.
    @MainActor
    static func terminateReply(for guards: [WorkspaceWindowCloseGuard]) -> NSApplication.TerminateReply {
        var confirmed: [(WorkspaceWindowCloseGuard, [UUID: String])] = []
        for proxy in guards {
            guard let workspace = proxy.workspace, workspace.hasDirtyTabs else { continue }
            let edits = unsavedEdits(of: workspace)
            proxy.window?.makeKeyAndOrderFront(nil)
            guard workspace.confirmCloseWithUnsavedChanges() else { return .terminateCancel }
            confirmed.append((proxy, edits))
        }
        for (proxy, edits) in confirmed { proxy.confirmedForQuit = edits }
        return .terminateNow
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let workspace {
            // Skip only if these exact edits were already answered for during quit.
            let answered = confirmedForQuit == Self.unsavedEdits(of: workspace)
            confirmedForQuit = nil
            guard answered || workspace.confirmCloseWithUnsavedChanges() else { return false }
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        isClosed = true
        original?.windowWillClose?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    @MainActor
    private static func unsavedEdits(of workspace: ProjectWorkspace) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: workspace.tabs.filter(\.isDirty).map { ($0.id, $0.source) })
    }
}
#endif
