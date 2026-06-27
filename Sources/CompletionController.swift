#if os(macOS)
import AppKit

/// One row in the completion list. `insert` replaces the in-progress word on accept.
struct CompletionItem: Equatable {
    let display: String   // shown in the list (commands include the leading backslash)
    let insert: String    // text inserted over the current word range
}

/// Non-activating panel so the text view keeps first-responder status while the list is up —
/// that is what lets typing / backspace keep editing the document and live-refilter the list.
final class CompletionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// VSCode-style async completion popup (CodeEdit / STTextView pattern): a child window that
/// stays open and re-filters in place instead of NSTextView's built-in pull-based popup, which
/// can't async-refresh and dismisses on backspace.
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: CompletionWindow?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [CompletionItem] = []
    private var monitor: Any?
    private weak var textView: LaTeXTextView?
    private var lastCaretRect = NSRect.zero
    private let rowHeight: CGFloat = 20
    private let maxRows = 12
    private let width: CGFloat = 360

    /// Invoked on any dismissal so the owner can cancel a pending async request (prevents
    /// an in-flight texlab reply from re-opening a popup the user just dismissed).
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
    }

    /// Show or update the list. Idempotent: if already visible it refreshes items + position in place.
    func show(items: [CompletionItem], caretRect: NSRect, in tv: LaTeXTextView) {
        guard !items.isEmpty else { close(); return }
        self.items = items
        self.textView = tv
        if panel == nil { makePanel() }
        let prev = tableView.selectedRow
        tableView.reloadData()
        let row = min(max(prev, 0), items.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        layout(caretRect: caretRect, in: tv)
        if !(panel?.isVisible ?? false) {
            guard let host = tv.window else { return }   // no window yet → don't install a stray monitor
            host.addChildWindow(panel!, ordered: .above)
            installMonitor()
        }
    }

    deinit { removeMonitor() }

    func close() {
        removeMonitor()
        onClose?()
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    // MARK: build / layout

    private func makePanel() {
        let p = CompletionWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isMovable = false
        p.isExcludedFromWindowsMenu = true

        let effect = NSVisualEffectView(frame: p.contentLayoutRect)
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        scrollView.frame = effect.bounds
        scrollView.autoresizingMask = [.width, .height]
        effect.addSubview(scrollView)
        p.contentView = effect
        panel = p
    }

    private func layout(caretRect: NSRect, in tv: NSTextView) {
        lastCaretRect = caretRect
        let rows = min(max(items.count, 1), maxRows)
        let height = CGFloat(rows) * rowHeight + 4
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 2)   // below caret
        if let vf = tv.window?.screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = caretRect.maxY + 2 }               // flip above
            origin.x = min(origin.x, vf.maxX - width - 4)
        }
        panel?.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    // MARK: key + mouse handling

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.keyCode {
            case 125: self.moveSelection(1);  return nil   // ↓
            case 126: self.moveSelection(-1); return nil   // ↑
            case 36, 48: self.acceptSelected(); return nil // Return, Tab
            case 53: self.close(); return nil              // Esc
            case 123, 124, 115, 119, 116, 121:             // ← → Home End PgUp PgDn
                self.close(); return event
            default: return event                          // letters / backspace edit + refilter
            }
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowDoubleClicked() { acceptSelected() }

    private func acceptSelected() {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { close(); return }
        let item = items[row]
        close()
        textView?.acceptCompletion(item)
    }

    // MARK: table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = items[row].display
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }
}

/// Rounded selection highlight (menu-like) instead of the default full-width blue bar.
private final class CompletionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        let r = bounds.insetBy(dx: 3, dy: 0)
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
    }
}
#endif
