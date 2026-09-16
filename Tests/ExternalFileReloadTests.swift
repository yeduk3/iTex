#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import iTex

@MainActor
final class ExternalFileReloadTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []
    /// Initial fixtures are root documents; otherwise the resolver scans ancestor folders ($TMPDIR).
    private static let preamble = "\\documentclass{article}\n"

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - Workspace decisions

    func testCleanTabReloadsExternalWrite() throws {
        let main = try fixture(["main.tex": Self.preamble + "Before"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        workspace.resolveExternalConflict = { _ in
            XCTFail("A clean editor must reload without asking")
            return false
        }
        try "After".write(to: main, atomically: true, encoding: .utf8)

        // FSEvents reports the real path (/private/var/…); the tab keeps the opened /var/… path.
        XCTAssertTrue(workspace.handleExternalChanges([realPath(main)]))

        let tab = try XCTUnwrap(workspace.activeTab)
        XCTAssertEqual(tab.source, "After")
        XCTAssertFalse(tab.isDirty)
    }

    func testOwnSaveNeitherReloadsNorPromptsNorRebuilds() throws {
        let main = try fixture(["main.tex": Self.preamble + "Before"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        var prompts = 0
        workspace.resolveExternalConflict = { _ in prompts += 1; return true }
        let tab = try XCTUnwrap(workspace.activeTab)

        tab.source = "Typed"
        try workspace.saveAll()
        XCTAssertFalse(workspace.handleExternalChanges([main]))
        XCTAssertEqual(tab.source, "Typed")
        XCTAssertFalse(tab.isDirty)

        // Typing again before the save's event arrives: disk still equals the baseline.
        tab.source = "Typed more"
        XCTAssertFalse(workspace.handleExternalChanges([main]))
        XCTAssertEqual(tab.source, "Typed more")

        // Disk written with exactly the buffer: just adopt it as saved.
        try "Typed more".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertFalse(workspace.handleExternalChanges([main]))
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(prompts, 0)
    }

    func testDirtyTabAsksOnceAndHonorsKeepOrReload() throws {
        let main = try fixture(["main.tex": Self.preamble + "Base"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        let tab = try XCTUnwrap(workspace.activeTab)
        var asked: [URL] = []

        // Keep: buffer stays, now dirty against the new disk content; repeats don't re-ask.
        workspace.resolveExternalConflict = { asked.append($0.url); return false }
        tab.source = "Mine"
        try "Theirs".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertFalse(workspace.handleExternalChanges([main]))
        XCTAssertFalse(workspace.handleExternalChanges([main]))
        XCTAssertEqual(asked, [main.standardizedFileURL])
        XCTAssertEqual(tab.source, "Mine")
        XCTAssertEqual(tab.savedSource, "Theirs")
        XCTAssertTrue(tab.isDirty)
        try workspace.saveAll()
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "Mine")

        // Reload: buffer replaced. A write + FSEvents delivery during the modal alert folds into
        // the same pass (no second alert) and the latest disk content wins.
        asked = []
        tab.source = "Mine again"
        try "Theirs 2".write(to: main, atomically: true, encoding: .utf8)
        workspace.resolveExternalConflict = { [unowned workspace] in
            asked.append($0.url)
            try? "Theirs 3".write(to: main, atomically: true, encoding: .utf8)
            XCTAssertFalse(workspace.handleExternalChanges([main]))
            return true
        }
        XCTAssertTrue(workspace.handleExternalChanges([main]))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(tab.source, "Theirs 3")
        XCTAssertFalse(tab.isDirty)
    }

    func testUnopenedSourceRebuildsButBuildOutputsDoNot() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\begin{document}\\input{child}\\end{document}",
            "child.tex": "Child"
        ])
        let main = root.appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)

        let child = root.appending(path: "child.tex")
        try "Child 2".write(to: child, atomically: true, encoding: .utf8)
        XCTAssertTrue(workspace.handleExternalChanges([child]))

        let pdf = root.appending(path: "main.pdf")
        let pdfTemp = root.appending(path: ".main.pdf.itex-\(UUID().uuidString).tmp")
        try Data("%PDF".utf8).write(to: pdf)
        try Data("%PDF".utf8).write(to: pdfTemp)
        XCTAssertFalse(workspace.handleExternalChanges([pdf, pdfTemp]))
    }

    /// Agent edit burst: requests while a rebuild waits coalesce; a change during a running rebuild
    /// schedules exactly one more, which starts only after the running one finishes.
    func testPreviewRebuildCoalescesAndTrailsRunningBuild() async throws {
        let main = try fixture(["main.tex": Self.preamble + "Body"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        var started = 0
        var gates: [CheckedContinuation<Void, Never>] = []
        workspace.rebuildPreview = { _ in
            started += 1
            await withCheckedContinuation { gates.append($0) }
        }

        workspace.schedulePreviewRebuild()
        workspace.schedulePreviewRebuild()
        workspace.schedulePreviewRebuild()
        var reached = await eventually { gates.count == 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(started, 1)

        workspace.schedulePreviewRebuild()
        workspace.schedulePreviewRebuild()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(started, 1, "The trailing rebuild must wait for the running one")

        gates[0].resume()
        reached = await eventually { gates.count == 2 }
        XCTAssertTrue(reached, "A change during a rebuild must get its own trailing rebuild")
        gates[1].resume()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(started, 2)
    }

    // MARK: - Editor

    func testMinimalReplacementKeepsCaretOutsideChangeAndIsUndoable() throws {
        let textView = LaTeXTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.allowsUndo = true   // as makeNSView configures it
        let window = makeWindow()
        window.contentView = textView
        let undoManager = try XCTUnwrap(textView.undoManager)
        textView.string = "alpha\nbeta\ngamma\n"
        undoManager.removeAllActions()
        // Tests dispatch no events, so group each step as the app's event loop would.
        undoManager.groupsByEvent = false
        func step(_ text: String) -> NSRange? {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return textView.replaceChangedRange(with: text)
        }

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(step("alpha\nBETA!\ngamma\n"), NSRange(location: 6, length: 5))
        XCTAssertEqual(textView.string, "alpha\nBETA!\ngamma\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        // A caret after the change shifts with it.
        textView.setSelectedRange(NSRange(location: 14, length: 0))   // "ga|mma"
        _ = step("alpha\nB\ngamma\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0))

        undoManager.undo()
        XCTAssertEqual(textView.string, "alpha\nBETA!\ngamma\n")
        undoManager.undo()
        XCTAssertEqual(textView.string, "alpha\nbeta\ngamma\n")
    }

    func testMinimalReplacementDoesNotSplitSurrogatePairs() {
        let textView = LaTeXTextView()
        textView.string = "a😀b"
        XCTAssertEqual(textView.replaceChangedRange(with: "a😃b"), NSRange(location: 1, length: 2))
        XCTAssertEqual(textView.string, "a😃b")
    }

    /// End to end through SwiftUI: a reload must reach the hosted NSTextView (Observation tracks
    /// `tab.source`), keep the caret, not echo back as a dirty edit, and stay undoable.
    func testReloadReachesHostedEditor() throws {
        let main = try fixture(["main.tex": Self.preamble + "beta\n"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        let host = NSHostingView(rootView: WorkspaceEditors(workspace: workspace))
        let window = makeWindow()
        window.contentView = host

        XCTAssertTrue(spin(host) { self.editor(in: host) != nil })
        let textView = try XCTUnwrap(editor(in: host))
        XCTAssertEqual(textView.string, Self.preamble + "beta\n")
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        try (Self.preamble + "BETA\n").write(to: main, atomically: true, encoding: .utf8)
        XCTAssertTrue(workspace.handleExternalChanges([main]))

        XCTAssertTrue(spin(host) { textView.string == Self.preamble + "BETA\n" })
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        let tab = try XCTUnwrap(workspace.activeTab)
        XCTAssertFalse(tab.isDirty)

        // Undoing the reload is an ordinary user edit: it writes back through the binding.
        try XCTUnwrap(textView.undoManager).undo()
        XCTAssertEqual(textView.string, Self.preamble + "beta\n")
        XCTAssertTrue(spin(host) { tab.source == Self.preamble + "beta\n" })
        XCTAssertTrue(tab.isDirty)
    }

    /// IME: a reload that lands mid-composition must not edit under the marked text; it applies
    /// once the composition commits.
    func testReloadDuringCompositionWaitsForCommit() throws {
        let main = try fixture(["main.tex": Self.preamble + "beta\n"]).appending(path: "main.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        workspace.resolveExternalConflict = { _ in true }   // marked text may have dirtied the tab
        let host = NSHostingView(rootView: WorkspaceEditors(workspace: workspace))
        makeWindow().contentView = host
        XCTAssertTrue(spin(host) { self.editor(in: host) != nil })
        let textView = try XCTUnwrap(editor(in: host))
        let tab = try XCTUnwrap(workspace.activeTab)

        let stale = Self.preamble + "beta\n"
        textView.setSelectedRange(NSRange(location: (stale as NSString).length, length: 0))
        textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        _ = spin(host, timeout: 0.2) { false }

        let reloaded = Self.preamble + "BETA\n"
        try reloaded.write(to: main, atomically: true, encoding: .utf8)
        XCTAssertTrue(workspace.handleExternalChanges([main]))
        _ = spin(host, timeout: 0.3) { false }
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.string, stale + "ㅎ")
        XCTAssertEqual(tab.source, reloaded, "The stale buffer must not echo over the reload")

        textView.insertText("하", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(spin(host) { textView.string == reloaded })
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(tab.source, reloaded)
        XCTAssertFalse(tab.isDirty)
    }

    // MARK: - Helpers

    private func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "itex-reload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        for (relativePath, source) in files {
            try source.write(to: root.appending(path: relativePath), atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    private func realPath(_ url: URL) -> URL {
        let path = url.path
        return URL(filePath: path.hasPrefix("/var/") ? "/private" + path : path)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func spin(_ host: NSView, timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func editor(in view: NSView) -> LaTeXTextView? {
        if let textView = view as? LaTeXTextView { return textView }
        for child in view.subviews {
            if let textView = editor(in: child) { return textView }
        }
        return nil
    }
}
#endif
