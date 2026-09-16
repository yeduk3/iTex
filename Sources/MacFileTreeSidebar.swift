#if os(macOS)
import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SwiftUI / AppKit boundary

/// The macOS sidebar deliberately ends its SwiftUI hierarchy here. NSOutlineView owns row hit
/// testing, selection painting, first-mouse behavior, keyboard navigation, and disclosure state.
struct SidebarView: View {
    let root: URL?
    let currentFile: URL?
    var onOpen: (URL) -> Void = { url in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    var body: some View {
        Group {
            if let root {
                MacFileTreeView(root: root, currentFile: currentFile, onOpen: onOpen)
                    .onDisappear { SidebarPreviewPanel.shared.hide() }
            } else {
                ContentUnavailableView(
                    "No Folder",
                    systemImage: "folder",
                    description: Text("Open a .tex file to browse its folder.")
                )
            }
        }
    }
}

struct MacFileTreeView: NSViewControllerRepresentable {
    let root: URL
    let currentFile: URL?
    let onOpen: (URL) -> Void

    func makeNSViewController(context: Context) -> MacFileTreeViewController {
        MacFileTreeViewController(root: root, currentFile: currentFile, onOpen: onOpen)
    }

    func updateNSViewController(_ controller: MacFileTreeViewController, context: Context) {
        controller.update(root: root, currentFile: currentFile, onOpen: onOpen)
    }

    static func dismantleNSViewController(
        _ controller: MacFileTreeViewController,
        coordinator: Void
    ) {
        controller.stop()
    }
}

// MARK: - Stable filesystem model

enum FileTreeIdentity: Hashable {
    case resource(AnyHashable)
    case path(String)

    static func make(url: URL, resourceIdentifier: Any?) -> FileTreeIdentity {
        if let object = resourceIdentifier as? NSObject {
            return .resource(AnyHashable(object))
        }
        return .path(url.standardizedFileURL.path)
    }
}

struct FileTreeDescriptor {
    let identity: FileTreeIdentity
    let url: URL
    let name: String
    let isDirectory: Bool
}

@MainActor
final class FileTreeNode: NSObject {
    let identity: FileTreeIdentity
    private(set) var url: URL
    private(set) var name: String
    private(set) var isDirectory: Bool
    weak var parent: FileTreeNode?
    fileprivate(set) var children: [FileTreeNode]?
    fileprivate let isRoot: Bool

    init(descriptor: FileTreeDescriptor, parent: FileTreeNode?, isRoot: Bool = false) {
        identity = descriptor.identity
        url = descriptor.url
        name = descriptor.name
        isDirectory = descriptor.isDirectory
        self.parent = parent
        self.isRoot = isRoot
    }

    fileprivate func apply(_ descriptor: FileTreeDescriptor) {
        url = descriptor.url
        name = descriptor.name
        isDirectory = descriptor.isDirectory
        if !isDirectory { children = nil }
    }
}

/// A reference graph that reuses node objects across scans. Resource identifiers let a node
/// survive a rename; standardized paths are the fallback for filesystems without identifiers.
@MainActor
final class FileTreeStore {
    private(set) var root: FileTreeNode
    private var nodesByIdentity: [FileTreeIdentity: FileTreeNode] = [:]
    private var nodesByPath: [String: FileTreeNode] = [:]

    init(rootURL: URL) {
        let normalized = rootURL.standardizedFileURL
        let descriptor = Self.descriptor(for: normalized, forceDirectory: true)
        root = FileTreeNode(descriptor: descriptor, parent: nil, isRoot: true)
        index(root)
    }

    var rootURL: URL { root.url }

    func ensureChildren(of node: FileTreeNode) -> [FileTreeNode] {
        guard node.isDirectory else { return [] }
        if node.children == nil { _ = reconcileChildren(of: node) }
        return node.children ?? []
    }

    @discardableResult
    func reconcileChildren(of parent: FileTreeNode) -> Bool {
        guard parent.isDirectory else { return false }
        let descriptors = Self.childrenDescriptors(of: parent.url)
        let previous = parent.children ?? []
        var claimed = Set<ObjectIdentifier>()
        var next: [FileTreeNode] = []
        next.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            let path = descriptor.url.standardizedFileURL.path
            let node = previous.first {
                !claimed.contains(ObjectIdentifier($0)) && $0.identity == descriptor.identity
            } ?? previous.first {
                !claimed.contains(ObjectIdentifier($0))
                    && $0.url.standardizedFileURL.path == path
            }
            if let node {
                claimed.insert(ObjectIdentifier(node))
                update(node, with: descriptor)
                node.parent = parent
                next.append(node)
            } else {
                let node = FileTreeNode(descriptor: descriptor, parent: parent)
                index(node)
                next.append(node)
            }
        }

        let retained = Set(next.map(ObjectIdentifier.init))
        for old in previous where !retained.contains(ObjectIdentifier(old)) {
            unindexSubtree(old)
            old.parent = nil
        }

        let changed = previous.map(\.identity) != next.map(\.identity)
            || zip(previous, next).contains { $0 !== $1 }
        parent.children = next
        return changed
    }

    func node(at url: URL) -> FileTreeNode? {
        nodesByPath[url.standardizedFileURL.path]
    }

    func node(with identity: FileTreeIdentity) -> FileTreeNode? {
        nodesByIdentity[identity]
    }

    /// Loads only the ancestors on the requested path, which is enough to reveal an active file.
    func revealNode(at url: URL) -> FileTreeNode? {
        let target = url.standardizedFileURL
        if let existing = node(at: target) { return existing }
        guard target.path == root.url.path || target.path.hasPrefix(root.url.path + "/") else {
            return nil
        }
        if target == root.url { return root }

        var cursor = root
        let relative = String(target.path.dropFirst(root.url.path.count))
            .split(separator: "/")
            .map(String.init)
        for component in relative {
            guard let child = ensureChildren(of: cursor).first(where: {
                $0.url.lastPathComponent == component
            }) else { return nil }
            cursor = child
        }
        return cursor
    }

    var loadedDirectories: [FileTreeNode] {
        nodesByPath.values.filter { $0.isDirectory && $0.children != nil }
    }

    private func update(_ node: FileTreeNode, with descriptor: FileTreeDescriptor) {
        let oldURL = node.url
        if oldURL.standardizedFileURL != descriptor.url.standardizedFileURL {
            removePathIndexes(from: node)
            node.apply(descriptor)
            rebaseDescendantURLs(of: node, from: oldURL, to: descriptor.url)
            addPathIndexes(from: node)
        } else {
            node.apply(descriptor)
            nodesByPath[descriptor.url.standardizedFileURL.path] = node
        }
        nodesByIdentity[node.identity] = node
    }

    private func rebaseDescendantURLs(of node: FileTreeNode, from oldBase: URL, to newBase: URL) {
        guard let children = node.children else { return }
        for child in children {
            let suffix = String(child.url.standardizedFileURL.path.dropFirst(oldBase.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let newURL = suffix.isEmpty
                ? newBase
                : newBase.appending(path: suffix)
            child.apply(
                FileTreeDescriptor(
                    identity: child.identity,
                    url: newURL.standardizedFileURL,
                    name: child.name,
                    isDirectory: child.isDirectory
                )
            )
            rebaseDescendantURLs(of: child, from: oldBase, to: newBase)
        }
    }

    private func index(_ node: FileTreeNode) {
        nodesByIdentity[node.identity] = node
        nodesByPath[node.url.standardizedFileURL.path] = node
    }

    private func unindexSubtree(_ node: FileTreeNode) {
        nodesByIdentity[node.identity] = nil
        nodesByPath[node.url.standardizedFileURL.path] = nil
        node.children?.forEach(unindexSubtree)
    }

    private func removePathIndexes(from node: FileTreeNode) {
        nodesByPath[node.url.standardizedFileURL.path] = nil
        node.children?.forEach(removePathIndexes)
    }

    private func addPathIndexes(from node: FileTreeNode) {
        nodesByPath[node.url.standardizedFileURL.path] = node
        node.children?.forEach(addPathIndexes)
    }

    static func descriptor(for url: URL, forceDirectory: Bool = false) -> FileTreeDescriptor {
        let normalized = url.standardizedFileURL
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .isDirectoryKey, .nameKey]
        let values = try? normalized.resourceValues(forKeys: keys)
        return FileTreeDescriptor(
            identity: .make(url: normalized, resourceIdentifier: values?.fileResourceIdentifier),
            url: normalized,
            name: values?.name ?? normalized.lastPathComponent,
            isDirectory: forceDirectory || (values?.isDirectory ?? false)
        )
    }

    static func childrenDescriptors(of directory: URL) -> [FileTreeDescriptor] {
        let keys: [URLResourceKey] = [.fileResourceIdentifierKey, .isDirectoryKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.map { descriptor(for: $0) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Explicit focus ownership

@MainActor
final class SidebarFocusController {
    static let shared = SidebarFocusController()

    private final class Entry {
        weak var window: NSWindow?
        weak var outlineView: NSOutlineView?
        weak var editor: LaTeXTextView?

        init(window: NSWindow, outlineView: NSOutlineView) {
            self.window = window
            self.outlineView = outlineView
        }
    }

    private var entries: [Entry] = []

    func register(_ outlineView: NSOutlineView, in window: NSWindow) {
        purge()
        if let entry = entries.first(where: { $0.window === window }) {
            entry.outlineView = outlineView
        } else {
            entries.append(Entry(window: window, outlineView: outlineView))
        }
    }

    func unregister(_ outlineView: NSOutlineView) {
        entries.removeAll { $0.outlineView == nil || $0.outlineView === outlineView }
    }

    func outline(in window: NSWindow?) -> NSOutlineView? {
        guard let window else { return nil }
        purge()
        return entries.first(where: { $0.window === window })?.outlineView
    }

    @discardableResult
    func focusSidebar(in window: NSWindow, remembering editor: LaTeXTextView? = nil) -> Bool {
        guard let entry = entry(for: window), let outline = entry.outlineView,
              outline.window === window, outline.acceptsFirstResponder else { return false }
        if let editor { entry.editor = editor }
        if responder(in: window, isInside: outline) { return true }
        return window.makeFirstResponder(outline)
    }

    func toggle(from editor: LaTeXTextView) {
        guard let window = editor.window, let entry = entry(for: window),
              let outline = entry.outlineView else { return }
        entry.editor = editor
        if responder(in: window, isInside: outline) {
            _ = window.makeFirstResponder(editor)
        } else {
            _ = focusSidebar(in: window, remembering: editor)
        }
    }

    func responder(in window: NSWindow, isInside outline: NSOutlineView) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === outline || responder.isDescendant(of: outline)
    }

    private func entry(for window: NSWindow) -> Entry? {
        purge()
        return entries.first { $0.window === window }
    }

    private func purge() {
        entries.removeAll { $0.window == nil || $0.outlineView == nil }
    }
}

// MARK: - FSEvents

private final class FileTreeDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private let onChange: ([URL]) -> Void
    private var pendingPaths: Set<String> = []
    private var delivery: DispatchWorkItem?

    init(onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
    }

    func start(url: URL) {
        let path = url.standardizedFileURL.path
        if stream != nil, watchedPath == path { return }
        stop()
        watchedPath = path
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileTreeDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            watcher.enqueue(Array(paths.prefix(Int(count))))
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        delivery?.cancel()
        delivery = nil
        pendingPaths.removeAll()
        guard let stream else {
            watchedPath = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPath = nil
    }

    private func enqueue(_ paths: [String]) {
        pendingPaths.formUnion(paths)
        delivery?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = self.pendingPaths.map { URL(filePath: $0).standardizedFileURL }
            self.pendingPaths.removeAll()
            self.onChange(urls)
        }
        delivery = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    deinit { stop() }
}

// MARK: - Native outline

final class MacFileTreeOutlineView: NSOutlineView {
    weak var owner: MacFileTreeViewController?
    private weak var registeredWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let registeredWindow, registeredWindow !== window {
            SidebarFocusController.shared.unregister(self)
        }
        registeredWindow = window
        if let window {
            SidebarFocusController.shared.register(self, in: window)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}":
            owner?.activateSelectedItem()
        case " ":
            owner?.togglePreview()
        default:
            super.keyDown(with: event)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        owner?.deleteSelectedItems()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu(for: event)
    }

}

@MainActor
final class MacFileTreeViewController: NSViewController {
    private(set) var store: FileTreeStore
    private(set) var outlineView = MacFileTreeOutlineView()
    private let scrollView = NSScrollView()
    private var watcher: FileTreeDirectoryWatcher?
    private var currentFile: URL?
    private var onOpen: (URL) -> Void
    private var isApplyingProgrammaticSelection = false
    private var previewOn = false
    private var editingNode: FileTreeNode?
    private var pendingFilesystemURLs: Set<URL> = []
    private var contextTargets: [FileTreeNode] = []

    static let previewableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "pdf", "gif", "tiff", "tif", "bmp", "heic"
    ]
    static let editorExtensions: Set<String> = [
        "tex", "bib", "sty", "cls", "txt", "md", "log"
    ]

    init(root: URL, currentFile: URL?, onOpen: @escaping (URL) -> Void) {
        store = FileTreeStore(rootURL: root)
        self.currentFile = currentFile?.standardizedFileURL
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
        startWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView

        outlineView.reloadData()
        outlineView.expandItem(store.root)
        DispatchQueue.main.async { [weak self] in self?.applyCurrentFileSelection() }
    }

    func update(root: URL, currentFile: URL?, onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        let normalizedRoot = root.standardizedFileURL
        if normalizedRoot != store.rootURL {
            SidebarPreviewPanel.shared.hide()
            previewOn = false
            store = FileTreeStore(rootURL: normalizedRoot)
            startWatcher()
            if isViewLoaded {
                outlineView.reloadData()
                outlineView.expandItem(store.root)
            }
        }
        let normalizedCurrent = currentFile?.standardizedFileURL
        if normalizedCurrent != self.currentFile {
            let old = self.currentFile
            self.currentFile = normalizedCurrent
            reloadVisibleRows(for: [old, normalizedCurrent].compactMap { $0 })
            applyCurrentFileSelection()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        SidebarPreviewPanel.shared.hide()
        SidebarFocusController.shared.unregister(outlineView)
    }

    private func configureOutlineView() {
        outlineView.owner = self
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.target = self
        outlineView.setAccessibilityIdentifier("FileTreeSidebar")
        outlineView.setAccessibilityLabel("File tree")
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileTreeColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    private func startWatcher() {
        watcher?.stop()
        let watcher = FileTreeDirectoryWatcher { [weak self] urls in
            self?.filesystemDidChange(urls)
        }
        watcher.start(url: store.rootURL)
        self.watcher = watcher
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        activate(node)
    }

    func activateSelectedItem() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        activate(node)
    }

    private func activate(_ node: FileTreeNode) {
        guard !node.isRoot else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                _ = store.ensureChildren(of: node)
                outlineView.expandItem(node)
            }
            return
        }

        previewOn = false
        SidebarPreviewPanel.shared.hide()
        if Self.editorExtensions.contains(node.url.pathExtension.lowercased()) {
            guard node.url.standardizedFileURL != currentFile else { return }
            onOpen(node.url)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    func togglePreview() {
        guard let node = selectedNodes.first, !node.isDirectory,
              Self.previewableExtensions.contains(node.url.pathExtension.lowercased()) else {
            previewOn = false
            SidebarPreviewPanel.shared.hide()
            return
        }
        previewOn.toggle()
        if previewOn {
            SidebarPreviewPanel.shared.show(url: node.url, anchoredTo: outlineView)
        } else {
            SidebarPreviewPanel.shared.hide()
        }
    }

    private var selectedNodes: [FileTreeNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileTreeNode }
            .filter { !$0.isRoot }
    }

    private func applyCurrentFileSelection() {
        guard isViewLoaded else { return }
        guard let currentFile else {
            isApplyingProgrammaticSelection = true
            outlineView.deselectAll(nil)
            isApplyingProgrammaticSelection = false
            return
        }
        guard let node = store.revealNode(at: currentFile) else { return }
        expandAncestors(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isApplyingProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isApplyingProgrammaticSelection = false
    }

    private func expandAncestors(of node: FileTreeNode) {
        var ancestors: [FileTreeNode] = []
        var cursor = node.parent
        while let current = cursor {
            ancestors.append(current)
            cursor = current.parent
        }
        for ancestor in ancestors.reversed() {
            _ = store.ensureChildren(of: ancestor)
            outlineView.expandItem(ancestor)
        }
    }

    private func reloadVisibleRows(for urls: [URL]) {
        guard isViewLoaded else { return }
        for url in urls {
            guard let node = store.node(at: url) else { continue }
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: [0]) }
        }
    }

    func filesystemDidChange(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if editingNode != nil || fieldEditorIsInsideOutline {
            pendingFilesystemURLs.formUnion(urls)
            return
        }
        refreshFilesystem(urls)
    }

    private var fieldEditorIsInsideOutline: Bool {
        guard let responder = outlineView.window?.firstResponder as? NSView,
              responder is NSTextView else { return false }
        return responder.isDescendant(of: outlineView)
    }

    private func refreshFilesystem(_ urls: [URL]) {
        guard isViewLoaded else { return }
        let selected = selectedNodes
        let selectedURLs = selected.map(\.url)
        let selectedIdentities = selected.map(\.identity)
        let fallbackRow = outlineView.selectedRow
        let expanded = expandedNodes
        let window = outlineView.window
        let focusWasInside = window.map {
            SidebarFocusController.shared.responder(in: $0, isInside: outlineView)
        } ?? false

        let parents = affectedLoadedDirectories(for: urls)
        var refreshedParents: [FileTreeNode] = []
        for parent in parents {
            // Reconciling an ancestor may remove a loaded descendant that was also reported by
            // FSEvents. Never ask NSOutlineView to reload that now-detached stale item.
            guard parent === store.root || store.node(at: parent.url) === parent else { continue }
            _ = store.reconcileChildren(of: parent)
            refreshedParents.append(parent)
        }
        for parent in refreshedParents {
            outlineView.reloadItem(parent, reloadChildren: true)
        }
        outlineView.expandItem(store.root)
        for node in expanded where outlineView.row(forItem: node) >= 0 {
            outlineView.expandItem(node)
        }
        restoreSelection(
            nodes: selected,
            identities: selectedIdentities,
            urls: selectedURLs,
            fallbackRow: fallbackRow
        )

        if focusWasInside, let window,
           !SidebarFocusController.shared.responder(in: window, isInside: outlineView) {
            _ = window.makeFirstResponder(outlineView)
        }
    }

    private var expandedNodes: [FileTreeNode] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? FileTreeNode,
                  outlineView.isItemExpanded(node) else { return nil }
            return node
        }
    }

    private func affectedLoadedDirectories(for urls: [URL]) -> [FileTreeNode] {
        var nodes: [ObjectIdentifier: FileTreeNode] = [:]
        for url in urls {
            let normalized = url.standardizedFileURL
            let candidates = [normalized, normalized.deletingLastPathComponent()]
            for candidate in candidates {
                if let node = store.node(at: candidate), node.isDirectory, node.children != nil {
                    nodes[ObjectIdentifier(node)] = node
                }
            }
        }
        if nodes.isEmpty { nodes[ObjectIdentifier(store.root)] = store.root }
        return nodes.values.sorted { $0.url.path.count < $1.url.path.count }
    }

    private func restoreSelection(
        nodes: [FileTreeNode],
        identities: [FileTreeIdentity],
        urls: [URL],
        fallbackRow: Int
    ) {
        var indexes = IndexSet()
        for node in nodes {
            let row = outlineView.row(forItem: node)
            if row >= 0 { indexes.insert(row) }
        }
        if indexes.isEmpty {
            for identity in identities {
                guard let node = store.node(with: identity) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { indexes.insert(row) }
            }
        }
        if indexes.isEmpty {
            for url in urls {
                guard let node = store.node(at: url) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { indexes.insert(row) }
            }
        }
        if indexes.isEmpty, fallbackRow >= 0, outlineView.numberOfRows > 1 {
            var row = min(fallbackRow, outlineView.numberOfRows - 1)
            if (outlineView.item(atRow: row) as? FileTreeNode)?.isRoot == true {
                row = min(row + 1, outlineView.numberOfRows - 1)
            }
            if row >= 0 { indexes.insert(row) }
        }
        isApplyingProgrammaticSelection = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
    }

    // MARK: Context menu and file operations

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        if row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode, !node.isRoot {
            if outlineView.selectedRowIndexes.contains(row) {
                contextTargets = selectedNodes
            } else {
                previewOn = false
                SidebarPreviewPanel.shared.hide()
                isApplyingProgrammaticSelection = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isApplyingProgrammaticSelection = false
                contextTargets = [node]
            }
            return makeItemMenu()
        }
        contextTargets = [store.root]
        return makeRootMenu()
    }

    private func makeRootMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open in Terminal", action: #selector(openInTerminal(_:))))
        menu.addItem(.separator())
        menu.addItem(item("New File…", action: #selector(newFile(_:))))
        menu.addItem(item("New Folder…", action: #selector(newFolder(_:))))
        return menu
    }

    private func makeItemMenu() -> NSMenu {
        let menu = NSMenu()
        if contextTargets.count == 1, contextTargets[0].isDirectory {
            menu.addItem(item("Open in Terminal", action: #selector(openInTerminal(_:))))
            menu.addItem(.separator())
            menu.addItem(item("New File…", action: #selector(newFile(_:))))
            menu.addItem(item("New Folder…", action: #selector(newFolder(_:))))
            menu.addItem(.separator())
        }
        if contextTargets.count == 1 {
            menu.addItem(item("Rename…", action: #selector(rename(_:))))
        }
        menu.addItem(item("Delete", action: #selector(deleteItems(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reveal in Finder", action: #selector(revealInFinder(_:))))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openInTerminal(_ sender: Any?) {
        guard let node = contextTargets.first else { return }
        ExternalTerminalLauncher.open(directory: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
    }

    @objc private func newFile(_ sender: Any?) {
        createItem(directory: contextDirectory, isDirectory: false)
    }

    @objc private func newFolder(_ sender: Any?) {
        createItem(directory: contextDirectory, isDirectory: true)
    }

    private var contextDirectory: URL {
        guard let node = contextTargets.first else { return store.rootURL }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func createItem(directory: URL, isDirectory: Bool) {
        let url = SidebarFileOperations.uniqueURL(
            in: directory,
            base: isDirectory ? "Untitled Folder" : "Untitled",
            extension: isDirectory ? "" : "tex"
        )
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
            refreshFilesystem([directory, url])
            guard let node = store.node(at: url) else { return }
            expandAncestors(of: node)
            beginRename(node)
        } catch {
            SidebarFileOperations.warn(
                isDirectory ? "Couldn't create the folder." : "Couldn't create the file.",
                error
            )
        }
    }

    @objc private func rename(_ sender: Any?) {
        guard contextTargets.count == 1, let node = contextTargets.first else { return }
        beginRename(node)
    }

    private func beginRename(_ node: FileTreeNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isApplyingProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        editingNode = node
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func deleteItems(_ sender: Any?) {
        delete(contextTargets.filter { !$0.isRoot })
    }

    func deleteSelectedItems() {
        delete(selectedNodes)
    }

    private func delete(_ nodes: [FileTreeNode]) {
        let unique = Dictionary(uniqueKeysWithValues: nodes.map { ($0.url.standardizedFileURL, $0) })
            .values
            .filter { node in
                !nodes.contains { other in
                    other !== node && node.url.path.hasPrefix(other.url.path + "/")
                }
            }
        guard !unique.isEmpty else { return }
        if let blocked = unique.first(where: { SidebarFileOperations.openConflict($0.url) }) {
            SidebarFileOperations.blocked(blocked.url, verb: "deleted")
            return
        }

        let alert = NSAlert()
        alert.messageText = unique.count == 1
            ? "Move “\(unique[unique.startIndex].url.lastPathComponent)” to the Trash?"
            : "Move \(unique.count) items to the Trash?"
        alert.informativeText = "You can restore them from the Trash later."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let oldRow = outlineView.selectedRow
        let parents = Set(unique.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        SidebarPreviewPanel.shared.hide()
        previewOn = false
        do {
            for node in unique {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            }
            refreshFilesystem(Array(parents))
            if outlineView.selectedRow < 0, outlineView.numberOfRows > 1 {
                let row = min(max(oldRow, 1), outlineView.numberOfRows - 1)
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } catch {
            SidebarFileOperations.warn("Couldn't move the item to the Trash.", error)
        }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let urls = contextTargets.filter { !$0.isRoot }.map(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.rootURL.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func move(_ urls: [URL], into folder: FileTreeNode) -> Bool {
        guard folder.isDirectory else { return false }
        var changed: Set<URL> = [folder.url]
        do {
            for source in urls {
                let normalized = source.standardizedFileURL
                guard normalized != folder.url,
                      !folder.url.path.hasPrefix(normalized.path + "/"),
                      normalized.deletingLastPathComponent() != folder.url else { continue }
                let destination = folder.url.appendingPathComponent(normalized.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    SidebarFileOperations.warn(
                        "An item named “\(normalized.lastPathComponent)” already exists in “\(folder.name)”."
                    )
                    continue
                }
                try FileManager.default.moveItem(at: normalized, to: destination)
                changed.insert(normalized.deletingLastPathComponent())
            }
            refreshFilesystem(Array(changed))
            return true
        } catch {
            SidebarFileOperations.warn("Couldn't move the item.", error)
            return false
        }
    }
}

// MARK: - Outline data source and delegate

extension MacFileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileTreeNode else { return 1 }
        return store.ensureChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileTreeNode else { return store.root }
        return store.ensureChildren(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileTreeNode, !node.isRoot else { return nil }
        return node.url as NSURL
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let target = (item as? FileTreeNode) ?? store.root
        return target.isDirectory ? .move : []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let target = (item as? FileTreeNode) ?? store.root
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
        return move(urls, into: target)
    }
}

extension MacFileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FileTreeNode)?.isRoot == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileTreeNode)?.isRoot != true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.isRoot ? "FileTreeHeader" : "FileTreeCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier, root: node.isRoot)
        configure(cell: cell, for: node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticSelection else { return }
        // Selection itself never activates a file or a preview. Space starts a new preview.
        previewOn = false
        SidebarPreviewPanel.shared.hide()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
        _ = store.ensureChildren(of: node)
    }

    private func makeCell(
        identifier: NSUserInterfaceItemIdentifier,
        root: Bool
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = textField
        cell.addSubview(textField)

        if root {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func configure(cell: NSTableCellView, for node: FileTreeNode) {
        cell.textField?.stringValue = node.isRoot
            ? (node.name.removingPercentEncoding ?? node.name)
            : node.name
        cell.textField?.isEditable = editingNode === node
        cell.textField?.isSelectable = editingNode === node
        if editingNode === node {
            cell.textField?.delegate = self
        } else {
            cell.textField?.delegate = nil
        }
        cell.textField?.font = node.isRoot
            ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            : .systemFont(
                ofSize: NSFont.systemFontSize,
                weight: node.url.standardizedFileURL == currentFile ? .semibold : .regular
            )
        cell.imageView?.image = node.isRoot ? nil : NSWorkspace.shared.icon(forFile: node.url.path)
        cell.setAccessibilityLabel(node.name)
    }
}

extension MacFileTreeViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let node = editingNode else { return }
        editingNode = nil
        let field = notification.object as? NSTextField
        field?.isEditable = false
        field?.isSelectable = false

        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let cancelled = movement == NSTextMovement.cancel.rawValue
        let proposed = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cancelled, !proposed.isEmpty, proposed != node.name, !proposed.contains("/") {
            let oldURL = node.url
            let destination = oldURL.deletingLastPathComponent().appendingPathComponent(proposed)
            if FileManager.default.fileExists(atPath: destination.path) {
                NSSound.beep()
                SidebarFileOperations.warn("An item named “\(proposed)” already exists.")
            } else {
                do {
                    try FileManager.default.moveItem(at: oldURL, to: destination)
                    refreshFilesystem([oldURL.deletingLastPathComponent(), destination])
                    if let renamed = store.node(with: node.identity) ?? store.node(at: destination) {
                        let row = outlineView.row(forItem: renamed)
                        if row >= 0 {
                            isApplyingProgrammaticSelection = true
                            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            isApplyingProgrammaticSelection = false
                        }
                    }
                } catch {
                    SidebarFileOperations.warn("Couldn't rename the item.", error)
                }
            }
        }

        if !pendingFilesystemURLs.isEmpty {
            let pending = Array(pendingFilesystemURLs)
            pendingFilesystemURLs.removeAll()
            refreshFilesystem(pending)
        } else if outlineView.row(forItem: node) >= 0 {
            outlineView.reloadItem(node)
        }
    }
}

// MARK: - File operation support

private enum SidebarFileOperations {
    static func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        let manager = FileManager.default
        func candidate(_ number: Int) -> URL {
            let stem = number == 1 ? base : "\(base) \(number)"
            return directory.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        var number = 1
        var url = candidate(number)
        while manager.fileExists(atPath: url.path) {
            number += 1
            url = candidate(number)
        }
        return url
    }

    static func openConflict(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.contains { document in
            guard let openPath = document.fileURL?.standardizedFileURL.path else { return false }
            return openPath == path || openPath.hasPrefix(path + "/")
        }
    }

    static func blocked(_ url: URL, verb: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(url.lastPathComponent)” is open and can't be \(verb)."
            alert.informativeText = "Close its window first."
            alert.runModal()
        }
    }

    static func warn(_ message: String, _ error: Error? = nil) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            if let error { alert.informativeText = error.localizedDescription }
            alert.runModal()
        }
    }
}
#endif
