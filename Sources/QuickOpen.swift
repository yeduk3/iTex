#if os(macOS)
import SwiftUI
import AppKit

/// One file in the quick-open palette (any non-hidden file under the root — the filename tier
/// lists everything; only the openable ones open as documents, the rest reveal in Finder).
struct QuickOpenItem: Identifiable {
    let url: URL
    let name: String      // file name
    let relPath: String   // path relative to the browsed root (matched + shown)
    var id: URL { url }
}

/// A full-text content hit: a file whose *contents* (not name) contain the query, shown in the
/// tier below the filename matches with the matching line number + a one-line snippet.
struct QuickOpenContentHit: Identifiable {
    let url: URL
    let name: String
    let relPath: String
    let line: Int         // 1-based line of the match (jumped to on open)
    let snippet: String   // one matching line, trimmed to ~80 chars around the hit
    var id: URL { url }
}

/// A pending "open this file, then jump to this line" intent, keyed by URL. Set just before a
/// content hit opens its document; consumed by the editor coordinator once that document's view
/// appears/updates. take() removes the entry, so consuming a jump twice (or never) is harmless.
final class PendingJump {
    static let shared = PendingJump()
    private let lock = NSLock()
    private var map: [URL: Int] = [:]

    func set(_ url: URL, line: Int) {
        lock.lock(); defer { lock.unlock() }
        map[url.standardizedFileURL] = line
    }
    func take(_ url: URL) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: url.standardizedFileURL)
    }
}

extension Notification.Name {
    /// Posted with userInfo ["url": URL, "line": Int] after opening a content hit; the matching
    /// window's editor coordinator jumps to the line (handles the already-open-document case).
    static let iTexJumpToLine = Notification.Name("iTexJumpToLine")
}

/// State for the ⌘P quick-open palette. Gathers the files under the current document's folder
/// once on show, then fuzzy-filters filenames as the user types and, in a second tier, searches
/// file contents off the main thread.
final class QuickOpenController: ObservableObject {
    @Published var isVisible = false
    @Published var query = "" { didSet { recompute() } }
    @Published var selectedIndex = 0
    @Published private(set) var results: [QuickOpenItem] = []
    /// Content-match tier, published asynchronously below the filename results.
    @Published private(set) var contentResults: [QuickOpenContentHit] = []
    private var files: [QuickOpenItem] = []
    private(set) var root: URL?

    /// Extensions that open as documents; everything else reveals in Finder.
    static let openableExts: Set<String> = ["tex", "bib", "sty", "cls", "txt", "md", "log"]
    /// Text extensions the content tier searches (excludes .log and binaries).
    static let textExts: Set<String> = ["tex", "bib", "sty", "cls", "txt", "md"]

    // Content search runs off the main thread, debounced, with a generation token so a slow
    // search for an old query can't overwrite the results of a newer one.
    private let searchQueue = DispatchQueue(label: "com.gyu.itex.quickopen.content", qos: .utility)
    private var pendingSearch: DispatchWorkItem?
    private var searchGeneration = 0
    private static let contentMinQuery = 2
    private static let contentHitCap = 30
    private static let contentFileSizeCap = 1_000_000

    /// Total selectable rows across both tiers — the flat index space ↑/↓ traverse.
    var totalCount: Int { results.count + contentResults.count }

    func show(root: URL?) {
        self.root = root
        files = Self.gather(root: root)
        contentResults = []
        query = ""        // didSet won't fire if already empty, so recompute explicitly below
        recompute()
        isVisible = true
    }

    func hide() {
        pendingSearch?.cancel()
        isVisible = false
    }

    /// Wrap-around move through BOTH tiers (driven by ↑/↓).
    func move(_ delta: Int) {
        let n = totalCount
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + delta + n) % n
    }

    /// URL for the currently selected row, mapping the flat index onto the filename tier then the
    /// content tier.
    func selectedURL() -> URL? {
        let idx = selectedIndex
        if results.indices.contains(idx) { return results[idx].url }
        let ci = idx - results.count
        return contentResults.indices.contains(ci) ? contentResults[ci].url : nil
    }

    /// Line to jump to if the selected row is a content hit; nil for filename hits.
    func selectedLine() -> Int? {
        let ci = selectedIndex - results.count
        return contentResults.indices.contains(ci) ? contentResults[ci].line : nil
    }

    private func recompute() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            results = Array(files.prefix(100))
            selectedIndex = 0
            scheduleContentSearch(q)
            return
        }
        var scored: [(item: QuickOpenItem, score: Int)] = []
        for item in files {
            if let s = matchScore(q, item) { scored.append((item, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.item.relPath.localizedStandardCompare(b.item.relPath) == .orderedAscending
        }
        results = scored.prefix(100).map { $0.item }
        selectedIndex = 0
        scheduleContentSearch(q)
    }

    /// Debounced, cancellable full-text search. Cancels any queued search, then — for a query of
    /// 2+ chars — dispatches a fresh one after 150 ms. Each search carries a generation number;
    /// when it finishes it only publishes if it is still the latest, so stale results are dropped.
    /// Typing never blocks: filename results already updated synchronously above.
    private func scheduleContentSearch(_ q: String) {
        pendingSearch?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        guard q.count >= Self.contentMinQuery else { contentResults = []; return }
        let filesSnapshot = files
        let exclude = Set(results.map { $0.url })   // don't repeat filename hits in this tier
        let work = DispatchWorkItem { [weak self] in
            let hits = QuickOpenController.contentSearch(query: q, files: filesSnapshot, exclude: exclude)
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.contentResults = hits
                if self.selectedIndex >= self.totalCount { self.selectedIndex = 0 }
            }
        }
        pendingSearch = work
        searchQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Case-insensitive substring scan over file contents. Only text files are searched; skips
    /// excluded (filename-tier) files and files over the size cap; stops at the hit cap.
    private static func contentSearch(query q: String, files: [QuickOpenItem],
                                      exclude: Set<URL>) -> [QuickOpenContentHit] {
        var hits: [QuickOpenContentHit] = []
        for item in files {
            if hits.count >= contentHitCap { break }
            if exclude.contains(item.url) { continue }
            guard textExts.contains(item.url.pathExtension.lowercased()) else { continue }
            if let size = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > contentFileSizeCap { continue }
            guard let content = try? String(contentsOf: item.url, encoding: .utf8),
                  let r = content.range(of: q, options: .caseInsensitive) else { continue }
            let line = content[content.startIndex..<r.lowerBound].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
            hits.append(QuickOpenContentHit(url: item.url, name: item.name, relPath: item.relPath,
                                            line: line, snippet: snippet(around: r, in: content)))
        }
        return hits
    }

    /// One-line snippet of the matching line, whitespace-collapsed and windowed to ~80 chars
    /// centered on the hit (with … elision when trimmed).
    private static func snippet(around r: Range<String.Index>, in content: String) -> String {
        let lineRange = content.lineRange(for: r)
        let line = content[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > 80 else { return line }
        let chars = Array(line)
        let hitInLine = content.distance(from: lineRange.lowerBound, to: r.lowerBound)
        let leadingTrim = content[lineRange].prefix(while: { $0 == " " || $0 == "\t" }).count
        let center = max(0, min(chars.count - 1, hitInLine - leadingTrim))
        let start = max(0, center - 40)
        let end = min(chars.count, start + 80)
        var out = String(chars[start..<end])
        if start > 0 { out = "…" + out }
        if end < chars.count { out += "…" }
        return out
    }

    /// Intuitive tiered ranking (higher = better). `q` is already lowercased. Filename prefix
    /// beats filename substring beats path substring beats a fuzzy subsequence fallback.
    private func matchScore(_ q: String, _ item: QuickOpenItem) -> Int? {
        let name = item.name.lowercased()
        let rel = item.relPath.lowercased()
        if name.hasPrefix(q) { return 3000 - name.count }
        if let r = name.range(of: q) {
            let pos = name.distance(from: name.startIndex, to: r.lowerBound)
            return 2000 - pos * 4 - name.count
        }
        if let r = rel.range(of: q) {
            let pos = rel.distance(from: rel.startIndex, to: r.lowerBound)
            return 1000 - pos * 2 - rel.count / 2
        }
        return fuzzyScore(q, rel)
    }

    /// Recursively collects every non-hidden regular file under `root` (packages skipped).
    private static func gather(root: URL?) -> [QuickOpenItem] {
        guard let root else { return [] }
        let rootPath = root.standardizedFileURL.path
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var out: [QuickOpenItem] = []
        for case let url as URL in en {
            if out.count >= 5000 { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let p = url.standardizedFileURL.path
            let rel = p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : url.lastPathComponent
            out.append(QuickOpenItem(url: url, name: url.lastPathComponent, relPath: rel))
        }
        return out.sorted { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
    }
}

/// Case-insensitive *tight* subsequence score: nil unless every matched character either
/// continues a contiguous run or starts a word (after a `/ -_.` separator). Higher is better.
func fuzzyScore(_ pattern: String, _ text: String) -> Int? {
    if pattern.isEmpty { return 0 }
    let pat = Array(pattern.lowercased())
    let txt = Array(text.lowercased())
    func isBoundary(_ i: Int) -> Bool { i == 0 || "/ -_.".contains(txt[i - 1]) }
    var pi = 0, score = 0, lastMatch = -2
    for (ti, ch) in txt.enumerated() {
        guard pi < pat.count, ch == pat[pi] else { continue }
        let contiguous = (lastMatch == ti - 1)
        let boundary = isBoundary(ti)
        guard contiguous || boundary else { return nil }         // reject loose/scattered hits
        score += contiguous ? 6 : 1                              // contiguous run bonus
        if boundary { score += 10 }                              // word-boundary bonus
        lastMatch = ti
        pi += 1
    }
    guard pi == pat.count else { return nil }
    return score - txt.count / 12
}

/// The ⌘P palette (shown as a sheet): a search field over a fuzzy-ranked list of files, plus a
/// content-match tier. The field is AppKit-backed so it reliably takes keyboard focus over the
/// detail. Typing filters; Return opens the selection, Esc closes, and clicking a row opens it.
/// `onOpen` receives the line to jump to for content hits, nil for filename hits.
struct QuickOpenPalette: View {
    @ObservedObject var controller: QuickOpenController
    let onOpen: (URL, Int?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenField(text: $controller.query,
                           onMoveUp: { controller.move(-1) },
                           onMoveDown: { controller.move(1) },
                           onSubmit: openSelected,
                           onCancel: controller.hide)
                .frame(height: 26)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            if controller.results.isEmpty && controller.contentResults.isEmpty {
                Text(controller.query.isEmpty ? "Type to search files in this folder"
                                              : "No matching files")
                    .foregroundStyle(.secondary)
                    .frame(width: 560, height: 360)
            } else {
                resultsList
            }
        }
        .frame(width: 560)
    }

    /// Filename tier, then (if any) a "Content matches" header + content tier — flattened into a
    /// single list. Every selectable row's identity IS its flat index, which is also what
    /// selection, ↑/↓, and scrollTo use; the non-selectable header takes id -1.
    private var rows: [PaletteRow] {
        var out: [PaletteRow] = []
        for (i, item) in controller.results.enumerated() { out.append(.file(index: i, item: item)) }
        if !controller.contentResults.isEmpty {
            out.append(.header)
            let base = controller.results.count
            for (j, hit) in controller.contentResults.enumerated() {
                out.append(.content(index: base + j, hit: hit))
            }
        }
        return out
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header:
                            ContentMatchesHeader()
                        case .file(let idx, let item):
                            // A plain row + tap gesture, NOT a Button: a Button is keyboard-
                            // focusable, so arrowing (which re-renders with a new selected row)
                            // let SwiftUI's focus engine steal first responder from the search
                            // field — breaking typing. Plain views aren't in the focus order.
                            QuickOpenRow(item: item, selected: idx == controller.selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    controller.selectedIndex = idx
                                    openSelected()
                                }
                        case .content(let idx, let hit):
                            QuickOpenContentRow(hit: hit, selected: idx == controller.selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    controller.selectedIndex = idx
                                    openSelected()
                                }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Explicit height — a ScrollView inside a sheet's fixed-frame VStack collapses to
            // height 0 with maxHeight:.infinity (ScrollViewReader doesn't propagate the flex).
            .frame(width: 560, height: 360)
            .onChange(of: controller.selectedIndex) { _, i in
                proxy.scrollTo(i, anchor: .center)
            }
        }
    }

    private func openSelected() {
        guard let url = controller.selectedURL() else { return }
        onOpen(url, controller.selectedLine())
    }
}

/// One row in the flattened two-tier palette list. Identity is the flat selection index for
/// selectable rows (`.file` / `.content`); the section header takes -1 (never selected).
private enum PaletteRow: Identifiable {
    case file(index: Int, item: QuickOpenItem)
    case header
    case content(index: Int, hit: QuickOpenContentHit)

    var id: Int {
        switch self {
        case .file(let i, _): return i
        case .header: return -1
        case .content(let i, _): return i
        }
    }
}

/// Quiet tier separator between filename and content matches.
private struct ContentMatchesHeader: View {
    var body: some View {
        Text("Content matches")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// AppKit text field for the palette: grabs first responder as soon as it's in the sheet window,
/// mirrors its text into the binding, and routes Return (open) / Esc (close) / ↑↓ (move).
private struct QuickOpenField: NSViewRepresentable {
    @Binding var text: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = "Open file in folder…"
        tf.font = .systemFont(ofSize: 18)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        context.coordinator.focus(tf)
        return tf
    }

    // Deliberately does NOT push `text` back into the field. The field is the source of truth for
    // the query (one-way: field → controlTextDidChange → binding). Writing `nsView.stringValue`
    // here clobbered the field editor mid-edit during rapid type+arrow, dropping keystrokes. The
    // palette is a fresh sheet each time it opens (field starts empty), so no push is needed.
    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // A query keystroke re-renders the palette; if that re-layout knocks the field off first
        // responder, re-grab it so the following keys still reach the field. No-op while focused
        // or composing.
        context.coordinator.reassertIfDropped(nsView)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField
        init(_ p: QuickOpenField) { parent = p }

        /// Force the sheet window key and make the field first responder. The sheet doesn't
        /// reliably steal key focus from the document window on its own, so retry over ~0.8s
        /// until the field editor actually holds first responder.
        func focus(_ tf: NSTextField, tries: Int = 40) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak tf] in
                guard let self, let tf else { return }
                if let win = tf.window {
                    // Already editing -> stop. Re-grabbing re-selects the whole field, so a
                    // never-matching success check made this fire makeFirstResponder 40×; each
                    // select-all clobbered fast typing so only the last char survived and the
                    // focus thrash killed the arrows. Korean masked it: short composed queries and
                    // the IME pinning the field editor through the storm.
                    if self.editing(tf, in: win) { return }
                    if !win.isKeyWindow { win.makeKeyAndOrderFront(nil) }
                    win.makeFirstResponder(tf)
                    if self.editing(tf, in: win) { return }
                }
                if tries > 0 { self.focus(tf, tries: tries - 1) }
            }
        }

        /// True when `field`'s editing session holds first responder. An edited NSTextField is
        /// never itself the window's first responder — the window's shared field editor (an
        /// NSTextView whose delegate is the field) is — so `=== field` / `isDescendant` checks on
        /// the field miss it. Check the field editor instead.
        func editing(_ field: NSControl, in win: NSWindow) -> Bool {
            let fr = win.firstResponder
            if fr === field { return true }
            if let editor = field.currentEditor(), fr === editor { return true }
            if let tv = fr as? NSTextView, (tv.delegate as AnyObject?) === field { return true }
            return false
        }

        /// Re-takes first responder if a SwiftUI re-render dropped it, then parks the caret at the
        /// end (makeFirstResponder select-alls the field, which would otherwise let the next
        /// keystroke replace the query). No-op when already editing — and an active IME
        /// composition keeps the field editor first responder, so this never re-grabs
        /// mid-composition and can't duplicate a marked syllable.
        func reassertIfDropped(_ tf: NSTextField) {
            guard let win = tf.window, !editing(tf, in: win) else { return }
            win.makeFirstResponder(tf)
            if let ed = tf.currentEditor() {
                ed.selectedRange = NSRange(location: (tf.stringValue as NSString).length, length: 0)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        /// Route the field editor's own command keys: ↑/↓ move the list selection, Return opens
        /// the selected match, Esc closes. Everything else (typing, ←/→, delete, ⌘A…) returns
        /// false so the field editor handles it normally — so the text is untouched.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                commitIME(textView); parent.onMoveUp(); reassertFocus(control); return true
            case #selector(NSResponder.moveDown(_:)):
                commitIME(textView); parent.onMoveDown(); reassertFocus(control); return true
            case #selector(NSResponder.insertNewline(_:)):
                commitIME(textView); parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default:
                return false
            }
        }

        /// Finalize any in-progress IME composition (e.g. a trailing Hangul syllable that stays
        /// "marked" because a search field never gets a space/enter to commit it) before
        /// ↑/↓/Return act on the list. Without this the marked syllable blocks list nav while text
        /// is present; committing it once (not re-inserting) lets the keys through.
        private func commitIME(_ textView: NSTextView) {
            if textView.hasMarkedText() { textView.unmarkText() }
        }

        /// The first selection change re-renders the list (and runs scrollTo), which can knock the
        /// field off first responder — so the SECOND arrow never reaches doCommandBy and nav
        /// appears stuck after one step. Re-assert focus next runloop. Safe for IME because
        /// commitIME() already unmarked any composition, so this won't re-insert a syllable.
        private func reassertFocus(_ control: NSControl) {
            DispatchQueue.main.async { [weak self, weak control] in
                guard let self, let control, let win = control.window else { return }
                if !self.editing(control, in: win) { win.makeFirstResponder(control) }
            }
        }
    }
}

private struct QuickOpenRow: View {
    let item: QuickOpenItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(selected ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                if item.relPath != item.name {
                    Text(item.relPath)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

/// A content-match row: `filename:line` primary, matching-line snippet as the secondary caption.
private struct QuickOpenContentRow: View {
    let hit: QuickOpenContentHit
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(hit.name):\(hit.line)")
                    .lineLimit(1)
                Text(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

// MARK: - ⌘P menu wiring

struct QuickOpenActionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    /// Invoked by the File ▸ Quick Open… (⌘P) menu item to raise the focused window's palette.
    var quickOpenAction: (() -> Void)? {
        get { self[QuickOpenActionKey.self] }
        set { self[QuickOpenActionKey.self] = newValue }
    }
}
#endif
