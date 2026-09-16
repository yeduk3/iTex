#if os(macOS)
import AppKit
import XCTest
@testable import iTex

@MainActor
final class WorkspaceClosePromptTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []
    /// Fixtures are root documents; otherwise the resolver scans ancestor folders ($TMPDIR).
    private static let preamble = "\\documentclass{article}\n"

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        retainedWorkspaces = []
        for url in temporaryDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - Workspace decision

    func testCleanWorkspaceClosesWithoutAsking() throws {
        let workspace = try makeWorkspace().workspace
        workspace.resolveUnsavedChanges = { _ in
            XCTFail("A clean workspace must close without asking")
            return .cancel
        }
        XCTAssertTrue(workspace.confirmCloseWithUnsavedChanges())
    }

    func testCancelKeepsBufferAndDisk() throws {
        let (workspace, main) = try makeWorkspace(body: "Disk")
        let tab = try XCTUnwrap(workspace.activeTab)
        tab.source = "Edited"
        var asked: [[URL]] = []
        workspace.resolveUnsavedChanges = { asked.append($0.map(\.url)); return .cancel }

        XCTAssertFalse(workspace.confirmCloseWithUnsavedChanges())
        XCTAssertEqual(asked, [[main.standardizedFileURL]])
        XCTAssertEqual(tab.source, "Edited")
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(try read(main), Self.preamble + "Disk")
    }

    func testSaveAllWritesEveryDirtyEditor() throws {
        let root = try fixture([
            "main.tex": Self.preamble + "Main",
            "child.tex": "Child",
            "clean.tex": "Clean"
        ])
        let main = root.appending(path: "main.tex")
        let child = root.appending(path: "child.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        workspace.openTab(child)
        workspace.openTab(root.appending(path: "clean.tex"))
        workspace.tabs[0].source = "Main edited"
        workspace.tabs[1].source = "Child edited"
        var asked: [[URL]] = []
        workspace.resolveUnsavedChanges = { asked.append($0.map(\.url)); return .saveAll }

        XCTAssertTrue(workspace.confirmCloseWithUnsavedChanges())
        XCTAssertEqual(asked, [[main.standardizedFileURL, child.standardizedFileURL]])
        XCTAssertEqual(try read(main), "Main edited")
        XCTAssertEqual(try read(child), "Child edited")
        XCTAssertFalse(workspace.hasDirtyTabs)
        XCTAssertNil(workspace.lastError)
    }

    func testDiscardClosesWithoutWriting() throws {
        let (workspace, main) = try makeWorkspace(body: "Disk")
        let tab = try XCTUnwrap(workspace.activeTab)
        tab.source = "Edited"
        workspace.resolveUnsavedChanges = { _ in .discard }

        XCTAssertTrue(workspace.confirmCloseWithUnsavedChanges())
        XCTAssertEqual(try read(main), Self.preamble + "Disk")
    }

    func testFailedSaveKeepsWindowOpenAndReportsError() throws {
        let (workspace, main) = try makeWorkspace(body: "Disk")
        let tab = try XCTUnwrap(workspace.activeTab)
        tab.source = "Edited"
        workspace.resolveUnsavedChanges = { _ in .saveAll }
        let root = main.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: main.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        XCTAssertFalse(workspace.confirmCloseWithUnsavedChanges())
        XCTAssertNotNil(workspace.lastError)
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(try read(main), Self.preamble + "Disk")
    }

    // MARK: - Window delegate proxy

    func testGuardGatesCloseAndForwardsToOriginalDelegate() throws {
        let workspace = try makeWorkspace().workspace
        let window = makeWindow()
        let stub = StubWindowDelegate()
        window.delegate = stub
        let proxy = WorkspaceWindowCloseGuard.install(on: window, workspace: workspace)
        XCTAssertTrue(window.delegate === proxy)
        XCTAssertTrue(WorkspaceWindowCloseGuard.live.contains(proxy))
        window.orderFront(nil)

        // Not implemented by the proxy: reaches the original delegate through forwarding.
        window.setContentSize(NSSize(width: 640, height: 420))
        XCTAssertEqual(stub.didResize, 1)

        // Dirty + Cancel: performClose (⌘W, close button) keeps the window; the original isn't asked.
        let tab = try XCTUnwrap(workspace.activeTab)
        tab.source = "Edited"
        var prompts = 0
        workspace.resolveUnsavedChanges = { _ in prompts += 1; return .cancel }
        window.performClose(nil)
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(window.isVisible)
        // The title-bar close button sends a private action, not performClose:.
        try XCTUnwrap(window.standardWindowButton(.closeButton)).performClick(nil)
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(stub.shouldCloseCalls, 0)
        XCTAssertEqual(stub.willClose, 0)

        // Clean, but the original delegate refuses: still open.
        try workspace.saveAll()
        stub.shouldClose = false
        window.performClose(nil)
        XCTAssertEqual(stub.shouldCloseCalls, 1)
        XCTAssertTrue(window.isVisible)

        // Clean and allowed: closes without asking; windowWillClose still reaches the original.
        stub.shouldClose = true
        window.performClose(nil)
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(stub.shouldCloseCalls, 2)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(stub.willClose, 1)
        XCTAssertFalse(WorkspaceWindowCloseGuard.live.contains(proxy))
    }

    func testReinstallIsIdempotentAndRefrontsReplacedDelegate() throws {
        let workspace = try makeWorkspace().workspace
        let window = makeWindow()
        let stub = StubWindowDelegate()
        window.delegate = stub
        let proxy = WorkspaceWindowCloseGuard.install(on: window, workspace: workspace)

        XCTAssertTrue(WorkspaceWindowCloseGuard.install(on: window, workspace: workspace) === proxy)
        XCTAssertTrue(window.delegate === proxy)
        window.setContentSize(NSSize(width: 640, height: 420))
        XCTAssertEqual(stub.didResize, 1, "Reinstall must neither wrap the proxy in itself nor double-forward")

        // SwiftUI swapped in another delegate: the next accessor update fronts that one instead.
        let replacement = StubWindowDelegate()
        window.delegate = replacement
        XCTAssertTrue(WorkspaceWindowCloseGuard.install(on: window, workspace: workspace) === proxy)
        XCTAssertTrue(window.delegate === proxy)
        window.setContentSize(NSSize(width: 660, height: 420))
        XCTAssertEqual(replacement.didResize, 1)
        XCTAssertEqual(stub.didResize, 1)

        try XCTUnwrap(workspace.activeTab).source = "Edited"
        workspace.resolveUnsavedChanges = { _ in .cancel }
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(replacement.shouldCloseCalls, 0)
        workspace.resolveUnsavedChanges = { _ in .discard }
        XCTAssertTrue(proxy.windowShouldClose(window))
        XCTAssertEqual(replacement.shouldCloseCalls, 1)
    }

    /// The proxy in front of a real SwiftUI WindowGroup window's delegate (the test host's welcome
    /// window — project windows come from the same scene type).
    func testGuardOnSwiftUIOwnedWindow() throws {
        guard let window = NSApp.windows.first(where: { window in
            window.isVisible && window.delegate.map { NSStringFromClass(type(of: $0)).contains("SwiftUI") } == true
        }) else {
            throw XCTSkip("No visible SwiftUI-owned window in the test host")
        }
        let swiftUIDelegate = try XCTUnwrap(window.delegate)
        defer { window.delegate = swiftUIDelegate }

        let workspace = try makeWorkspace().workspace
        let proxy = WorkspaceWindowCloseGuard.install(on: window, workspace: workspace)
        try XCTUnwrap(workspace.activeTab).source = "Edited"
        var prompts = 0
        workspace.resolveUnsavedChanges = { _ in prompts += 1; return .cancel }

        let frame = window.frame
        window.setFrame(frame.insetBy(dx: 10, dy: 10), display: true)
        spin(0.5)
        window.setFrame(frame, display: true)
        spin(0.5)
        XCTAssertTrue(window.delegate === proxy, "SwiftUI replaced the delegate")

        window.performClose(nil)
        spin(0.3)
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(window.isVisible)
        try XCTUnwrap(window.standardWindowButton(.closeButton)).performClick(nil)
        spin(0.3)
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.delegate === proxy)
    }

    // MARK: - Quit

    func testQuitCancelsWhenAnyProjectWindowCancels() throws {
        let (first, firstWindow) = try makeGuardedWindow()
        let (second, _) = try makeGuardedWindow()
        var firstPrompts = 0
        try dirty(first).resolveUnsavedChanges = { _ in firstPrompts += 1; return .discard }
        try dirty(second).resolveUnsavedChanges = { _ in .cancel }

        let live = WorkspaceWindowCloseGuard.live
        XCTAssertTrue(live.contains(first) && live.contains(second))
        XCTAssertEqual(WorkspaceWindowCloseGuard.terminateReply(for: [first, second]), .terminateCancel)
        XCTAssertEqual(firstPrompts, 1)

        // The abandoned quit must not pre-answer a later close.
        XCTAssertTrue(first.windowShouldClose(firstWindow))
        XCTAssertEqual(firstPrompts, 2)
    }

    func testQuitProceedsWhenAllConfirmAndAsksOncePerWindow() throws {
        let (discarding, discardingWindow) = try makeGuardedWindow()
        let (saving, savingWindow) = try makeGuardedWindow()
        let (clean, _) = try makeGuardedWindow()
        var discardPrompts = 0
        var savePrompts = 0
        try dirty(discarding).resolveUnsavedChanges = { _ in discardPrompts += 1; return .discard }
        try dirty(saving).resolveUnsavedChanges = { _ in savePrompts += 1; return .saveAll }
        try XCTUnwrap(clean.workspace).resolveUnsavedChanges = { _ in
            XCTFail("A clean window must not ask on quit")
            return .cancel
        }

        let guards = WorkspaceWindowCloseGuard.live.filter { [discarding, saving, clean].contains($0) }
        XCTAssertEqual(guards.count, 3)
        XCTAssertEqual(WorkspaceWindowCloseGuard.terminateReply(for: guards), .terminateNow)
        XCTAssertEqual(discardPrompts, 1)
        XCTAssertEqual(savePrompts, 1)
        XCTAssertFalse(try XCTUnwrap(saving.workspace).hasDirtyTabs)

        // Termination routed through windowShouldClose: already answered, no second prompt.
        XCTAssertTrue(discarding.windowShouldClose(discardingWindow))
        XCTAssertTrue(saving.windowShouldClose(savingWindow))
        XCTAssertEqual(discardPrompts, 1)
        XCTAssertEqual(savePrompts, 1)

        // That answer is one-shot and tied to those edits.
        XCTAssertTrue(discarding.windowShouldClose(discardingWindow))
        XCTAssertEqual(discardPrompts, 2)
    }

    func testQuitAnswerDoesNotCoverLaterEdits() throws {
        let (proxy, window) = try makeGuardedWindow()
        let workspace = try dirty(proxy)
        var prompts = 0
        workspace.resolveUnsavedChanges = { _ in prompts += 1; return .discard }
        XCTAssertEqual(WorkspaceWindowCloseGuard.terminateReply(for: [proxy]), .terminateNow)

        try XCTUnwrap(workspace.activeTab).source = "Edited again"
        workspace.resolveUnsavedChanges = { _ in prompts += 1; return .cancel }
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(prompts, 2)
    }

    // MARK: - Helpers

    private func makeWorkspace(body: String = "Body") throws -> (workspace: ProjectWorkspace, main: URL) {
        let main = try fixture(["main.tex": Self.preamble + body]).appending(path: "main.tex")
        return (ProjectWorkspace(initialURL: main, tracksRecentDocuments: false), main)
    }

    /// Workspaces are owned by their SwiftUI view; the proxy holds them weakly, so keep them alive.
    private var retainedWorkspaces: [ProjectWorkspace] = []

    private func makeGuardedWindow() throws -> (WorkspaceWindowCloseGuard, NSWindow) {
        let workspace = try makeWorkspace().workspace
        retainedWorkspaces.append(workspace)
        let window = makeWindow()
        return (WorkspaceWindowCloseGuard.install(on: window, workspace: workspace), window)
    }

    private func dirty(_ proxy: WorkspaceWindowCloseGuard) throws -> ProjectWorkspace {
        let workspace = try XCTUnwrap(proxy.workspace)
        try XCTUnwrap(workspace.activeTab).source = "Edited"
        return workspace
    }

    private func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "itex-close-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        for (relativePath, source) in files {
            try source.write(to: root.appending(path: relativePath), atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private final class StubWindowDelegate: NSObject, NSWindowDelegate {
    var shouldClose = true
    private(set) var shouldCloseCalls = 0
    private(set) var didResize = 0
    private(set) var willClose = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCalls += 1
        return shouldClose
    }

    func windowDidResize(_ notification: Notification) { didResize += 1 }
    func windowWillClose(_ notification: Notification) { willClose += 1 }
}
#endif
