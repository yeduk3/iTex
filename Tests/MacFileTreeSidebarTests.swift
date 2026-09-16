#if os(macOS)
import AppKit
import XCTest
@testable import iTex

@MainActor
final class MacFileTreeSidebarTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testStoreKeepsReferenceIdentityAcrossSiblingChangesAndRename() throws {
        let root = try makeDirectory()
        let original = root.appendingPathComponent("main.tex")
        try Data("test".utf8).write(to: original)

        let store = FileTreeStore(rootURL: root)
        _ = store.ensureChildren(of: store.root)
        let originalNode = try XCTUnwrap(store.node(at: original))

        let sibling = root.appendingPathComponent("notes.tex")
        try Data("notes".utf8).write(to: sibling)
        store.reconcileChildren(of: store.root)
        XCTAssertTrue(store.node(at: original) === originalNode)

        let renamed = root.appendingPathComponent("renamed.tex")
        try FileManager.default.moveItem(at: original, to: renamed)
        store.reconcileChildren(of: store.root)
        XCTAssertTrue(store.node(at: renamed) === originalNode)
        XCTAssertEqual(originalNode.url, renamed.standardizedFileURL)
    }

    func testSelectionDoesNotOpenUntilExplicitActivation() throws {
        let root = try makeDirectory()
        let first = root.appendingPathComponent("a.tex")
        let second = root.appendingPathComponent("b.tex")
        try Data().write(to: first)
        try Data().write(to: second)
        var opened: [URL] = []
        let controller = MacFileTreeViewController(root: root, currentFile: nil) {
            opened.append($0.standardizedFileURL)
        }
        controller.loadViewIfNeeded()
        controller.update(root: root, currentFile: first, onOpen: {
            opened.append($0.standardizedFileURL)
        })

        let secondNode = try XCTUnwrap(controller.store.node(at: second))
        let row = controller.outlineView.row(forItem: secondNode)
        XCTAssertGreaterThanOrEqual(row, 0)
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(opened.isEmpty)

        controller.update(root: root, currentFile: second, onOpen: {
            opened.append($0.standardizedFileURL)
        })
        XCTAssertTrue(opened.isEmpty, "Programmatic reveal/select must not feed back into open")

        controller.update(root: root, currentFile: first, onOpen: {
            opened.append($0.standardizedFileURL)
        })
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.activateSelectedItem()
        XCTAssertEqual(opened, [second.standardizedFileURL])
        controller.stop()
    }

    func testFilesystemRefreshPreservesSelectionExpansionAndResponderOwnership() throws {
        let root = try makeDirectory()
        let folder = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let selectedURL = folder.appendingPathComponent("main.tex")
        try Data().write(to: selectedURL)

        let controller = MacFileTreeViewController(root: root, currentFile: nil) { _ in
            XCTFail("Refresh must not activate a file")
        }
        controller.loadViewIfNeeded()
        let window = makeWindow(containing: controller.view)
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        let folderNode = try XCTUnwrap(controller.store.revealNode(at: folder))
        _ = controller.store.ensureChildren(of: folderNode)
        controller.outlineView.expandItem(folderNode)
        let selectedNode = try XCTUnwrap(controller.store.node(at: selectedURL))
        let selectedRow = controller.outlineView.row(forItem: selectedNode)
        controller.outlineView.selectRowIndexes(
            IndexSet(integer: selectedRow),
            byExtendingSelection: false
        )
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))

        let sibling = folder.appendingPathComponent("sibling.tex")
        try Data().write(to: sibling)
        controller.filesystemDidChange([sibling])

        XCTAssertTrue(controller.outlineView.item(atRow: controller.outlineView.selectedRow)
            as? FileTreeNode === selectedNode)
        XCTAssertTrue(controller.outlineView.isItemExpanded(folderNode))
        XCTAssertTrue(window.firstResponder === controller.outlineView)

        let editorSurrogate = NSTextView(frame: NSRect(x: 300, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(editorSurrogate)
        XCTAssertTrue(window.makeFirstResponder(editorSurrogate))
        let anotherSibling = folder.appendingPathComponent("third.tex")
        try Data().write(to: anotherSibling)
        controller.filesystemDidChange([anotherSibling])
        XCTAssertTrue(window.firstResponder === editorSurrogate, "A refresh must not steal editor focus")
    }

    func testFocusControllerUsesRegisteredOutlineNotAnotherTable() throws {
        let root = try makeDirectory()
        try Data().write(to: root.appendingPathComponent("main.tex"))
        let controller = MacFileTreeViewController(root: root, currentFile: nil) { _ in }
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.outlineView.style, .sourceList)
        XCTAssertTrue(controller.outlineView.acceptsFirstMouse(for: nil))

        let otherTable = NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        otherTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("other")))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        container.addSubview(otherTable)
        controller.view.frame = NSRect(x: 120, y: 0, width: 300, height: 400)
        container.addSubview(controller.view)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        _ = window.makeFirstResponder(otherTable)
        XCTAssertTrue(SidebarFocusController.shared.focusSidebar(in: window))
        XCTAssertTrue(window.firstResponder === controller.outlineView)
        XCTAssertTrue(SidebarFocusController.shared.outline(in: window) === controller.outlineView)
    }

    func testFocusShortcutTogglesBetweenEditorAndRegisteredOutline() throws {
        let root = try makeDirectory()
        try Data().write(to: root.appendingPathComponent("main.tex"))
        let controller = MacFileTreeViewController(root: root, currentFile: nil) { _ in }
        controller.loadViewIfNeeded()
        let editor = LaTeXTextView(frame: NSRect(x: 320, y: 0, width: 160, height: 300))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        container.addSubview(controller.view)
        container.addSubview(editor)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            controller.stop()
            window.orderOut(nil)
        }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "E",
                charactersIgnoringModifiers: "e",
                isARepeat: false,
                keyCode: 14
            )
        )

        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(window.firstResponder === controller.outlineView)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testPreviewPanelDoesNotTakeOutlineFocus() throws {
        let root = try makeDirectory()
        let imageURL = root.appendingPathComponent("image.png")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: imageURL)

        let controller = MacFileTreeViewController(root: root, currentFile: nil) { _ in }
        controller.loadViewIfNeeded()
        let window = makeWindow(containing: controller.view)
        defer {
            SidebarPreviewPanel.shared.hide()
            controller.stop()
            window.orderOut(nil)
        }
        let node = try XCTUnwrap(controller.store.node(at: imageURL))
        let row = controller.outlineView.row(forItem: node)
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))

        controller.togglePreview()
        XCTAssertTrue(window.firstResponder === controller.outlineView)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iTex-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        return window
    }
}
#endif
