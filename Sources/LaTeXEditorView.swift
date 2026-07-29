import SwiftUI

#if os(macOS)
import AppKit
import Combine

// MARK: - NSTextView subclass

final class LaTeXTextView: NSTextView {
    enum CompletionContext { case command, brace, option, none }

    // MARK: - LaTeX structure decoration

    /// The latest lightweight parse. The ruler consumes this snapshot without reparsing text.
    internal private(set) var structureSnapshot: LaTeXStructureSnapshot = .empty
    /// Pairs containing the caret, ordered from the outermost environment to the innermost.
    internal private(set) var activeEnvironmentPairs: [LaTeXEnvironmentPair] = []

    /// A stable six-color depth palette shared with the gutter's scope annotations.
    static func pairColor(forDepth depth: Int) -> NSColor {
        let palette: [NSColor] = [
            .systemTeal, .systemPurple, .systemOrange,
            .systemPink, .systemGreen, .systemIndigo,
        ]
        return palette[max(0, depth) % palette.count]
    }

    /// Reparse only after source changes, then run syntax and structural foreground decoration
    /// as one pass so a regular syntax refresh cannot erase environment colors.
    func refreshStructureHighlighting() {
        let snapshot = LaTeXStructureAnalyzer.analyze(string)
        structureSnapshot = snapshot
        updateActiveEnvironmentPairs(repaint: false)
        if let lm = layoutManager {
            Syntax.apply(to: lm, string: string, structureSnapshot: snapshot)
        }
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Selection changes reuse the latest snapshot; moving the caret never reparses the buffer.
    private func updateActiveEnvironmentPairs(repaint: Bool = true) {
        let length = (string as NSString).length
        let offset = min(selectedRange().location, length)
        activeEnvironmentPairs = structureSnapshot
            .pairs(containingUTF16Offset: offset)
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.fullRange.length > rhs.fullRange.length
            }
        if repaint {
            needsDisplay = true
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    /// Classify the cursor position for completion: `\command`, `\cmd{arg`, `\cmd[opt`, or none.
    func completionContext(at loc: Int) -> CompletionContext {
        let ns = string as NSString
        guard loc > 0 else { return .none }
        // Trailing letter run, then look at the delimiter just before it.
        var w = loc
        while w > 0, isAsciiLetter(ns.character(at: w - 1)) { w -= 1 }
        if w > 0, ns.character(at: w - 1) == 0x5C { return .command }   // \word
        // Scan back on the current line for an open { or [ tied to a \command.
        var j = loc
        while j > 0 {
            let c = ns.character(at: j - 1)
            if c == 0x0A || c == 0x7D || c == 0x5D { return .none }     // newline / } / ] → closed
            if c == 0x7B { return precededByCommand(beforeBrace: j - 1) ? .brace : .none }   // {
            if c == 0x5B { return precededByCommand(beforeBrace: j - 1) ? .option : .none }  // [
            j -= 1
        }
        return .none
    }

    private func precededByCommand(beforeBrace open: Int) -> Bool {
        let ns = string as NSString
        var k = open
        while k > 0, isAsciiLetter(ns.character(at: k - 1)) { k -= 1 }
        return k < open && k > 0 && ns.character(at: k - 1) == 0x5C
    }

    // MARK: - Completion (custom child-window popup, VSCode-style)

    lazy var completion: CompletionController = {
        let c = CompletionController()
        c.onClose = { [weak self] in self?.cancelPendingCompletion() }
        return c
    }()
    private var completionWordRange = NSRange(location: 0, length: 0)
    private var completionGen = 0
    private var completionTask: Task<Void, Never>?
    private var isApplyingEdit = false

    // MARK: - Snippet session (tab-stop navigation after accepting a completion)
    private var snippetStops: [SnippetStop] = []   // active stops, ranges in document coordinates
    private var snippetRange = NSRange(location: 0, length: 0)   // whole snippet span
    private var snippetFinal = 0                    // $0 position (document coordinate)
    private var snippetCurrent = -1
    private var snippetActive = false

    /// Invalidate any in-flight texlab request so a late reply can't re-open the popup.
    private func cancelPendingCompletion() {
        completionTask?.cancel()
        completionGen += 1
    }

    /// Word range the popup completes. Command context includes the leading backslash.
    private func currentWordRange(_ ctx: CompletionContext) -> NSRange {
        let ns = string as NSString
        let loc = selectedRange().location
        var start = loc
        while start > 0, isAsciiLetter(ns.character(at: start - 1)) { start -= 1 }
        if ctx == .command, start > 0, ns.character(at: start - 1) == 0x5C { start -= 1 }
        return NSRange(location: start, length: loc - start)
    }

    private func buildCandidates(_ ctx: CompletionContext, prefix: String) -> [CompletionItem] {
        let server = (delegate as? Coordinator)?.texLabClient?.latestCompletions ?? []
        var seen = Set<String>(), out: [CompletionItem] = []
        func add(_ display: String, snippet: String? = nil) {
            guard display.hasPrefix(prefix), display != prefix, seen.insert(display).inserted else { return }
            out.append(CompletionItem(display: display, insert: display, snippet: snippet))
        }
        switch ctx {
        case .command, .none:
            for c in server { add("\\" + c.label, snippet: lspSnippet(c.insertText, command: true)) }
            for e in LaTeXCommands.environments { add("\\" + e) }
            for s in LaTeXCommands.all { add(s) }
        case .brace:
            for c in server { add(c.label, snippet: lspSnippet(c.insertText, command: false)) }
        case .option:
            for k in LaTeXCommands.optionKeys { add(k) }
        }
        return out
    }

    /// Keep an LSP snippet only when it actually carries placeholders; re-anchor the leading
    /// backslash for command context (our word range includes it, texlab's newText does not).
    private func lspSnippet(_ insertText: String, command: Bool) -> String? {
        guard insertText.contains("$") else { return nil }
        guard command else { return insertText }
        var s = insertText
        if s.hasPrefix("\\") { s.removeFirst() }
        return "\\" + s
    }

    /// Re-filter from the cache and show/update the popup instantly — no server round-trip.
    private func refilterCompletion() {
        let ctx = completionContext(at: selectedRange().location)
        guard ctx != .none else { completion.close(); return }
        let wordRange = currentWordRange(ctx)
        let prefix = (string as NSString).substring(with: wordRange)
        let items = buildCandidates(ctx, prefix: prefix)
        guard !items.isEmpty else { completion.close(); return }
        completionWordRange = wordRange
        let caret = firstRect(forCharacterRange: NSRange(location: wordRange.location, length: 0), actualRange: nil)
        completion.show(items: items, caretRect: caret, in: self)
    }

    /// Debounced, cancellable texlab fetch; on a still-valid reply, re-filter in place.
    private func requestServerCompletion() {
        guard let client = (delegate as? Coordinator)?.texLabClient else { return }
        completionTask?.cancel()
        completionGen += 1
        let gen = completionGen
        let caret = selectedRange().location
        let (line, col) = lspPosition(in: string, at: caret)
        completionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            if Task.isCancelled || gen != self.completionGen { return }
            client.changeDocument(text: self.string)             // sync LSP before asking (fixes race)
            _ = await client.requestCompletions(line: line, character: col)
            if Task.isCancelled || gen != self.completionGen { return }
            if self.selectedRange().location != caret { return }  // caret moved → drop stale result
            self.refilterCompletion()
        }
    }

    /// After every edit: open/refresh from cache instantly, then warm from texlab.
    private func updateCompletionAfterEdit() {
        let ctx = completionContext(at: selectedRange().location)
        guard ctx != .none else { completion.close(); return }
        refilterCompletion()
        if ctx != .option { requestServerCompletion() }
    }

    /// Caret moved (click / arrow / edit) → dismiss the error popover; dismiss completion on non-edit moves.
    private var highlightLineRect: NSRect?
    func handleSelectionChange() {
        errorPopover.close()
        updateActiveEnvironmentPairs()
        // Caret leaving the snippet's overall span ends the session (programmatic stop moves stay inside).
        if snippetActive {
            let sel = selectedRange()
            if sel.location < snippetRange.location || NSMaxRange(sel) > NSMaxRange(snippetRange) { endSnippetSession() }
        }
        if !isApplyingEdit, completion.isVisible { completion.close() }
        // Move the current-line highlight: repaint the old line and the new one.
        let newRect = currentLineFragmentRect()
        if let old = highlightLineRect { setNeedsDisplay(old) }
        if let new = newRect { setNeedsDisplay(new) }
        highlightLineRect = newRect
    }

    /// Accept the highlighted item. A wrappable environment expands straight to
    /// `\begin{env}…\end{env}` (one step — no intermediate `\env` then Tab).
    func acceptCompletion(_ item: CompletionItem) {
        if item.insert.hasPrefix("\\"), Self.knownEnvironments.contains(String(item.insert.dropFirst())) {
            expandEnvironment(String(item.insert.dropFirst()), replacing: completionWordRange)
            return
        }
        let snippet = snippetForItem(item)
        if let snippet, snippet.hasStops {
            beginSnippetSession(snippet, replacing: completionWordRange)
            return
        }
        let text = snippet?.text ?? item.insert
        let caret = completionWordRange.location + (snippet?.finalCaret ?? (item.insert as NSString).length)
        replace(range: completionWordRange, with: text, newSelection: NSRange(location: caret, length: 0))
    }

    /// Snippet for an accepted item: an explicit LSP snippet, else a static brace template, else
    /// any empty brace groups already in the insert text. nil → plain insert.
    private func snippetForItem(_ item: CompletionItem) -> Snippet? {
        if let src = item.snippet { return Snippet.parse(src) }
        if item.insert.hasPrefix("\\"),
           let tmpl = LaTeXCommands.snippetTemplates[String(item.insert.dropFirst())] {
            return Snippet.fromEmptyGroups(tmpl)
        }
        return Snippet.fromEmptyGroups(item.insert)
    }

    // MARK: - Snippet session

    /// Insert the snippet as one undo step, re-base stops into document coordinates, select the first.
    private func beginSnippetSession(_ snippet: Snippet, replacing range: NSRange) {
        endSnippetSession()
        let base = range.location
        guard replace(range: range, with: snippet.text, newSelection: NSRange(location: base, length: 0)) else { return }
        snippetStops = snippet.stops.map {
            SnippetStop(index: $0.index,
                        range: NSRange(location: base + $0.range.location, length: $0.range.length),
                        placeholder: $0.placeholder)
        }
        snippetRange = NSRange(location: base, length: (snippet.text as NSString).length)
        snippetFinal = base + snippet.finalCaret
        snippetCurrent = -1
        snippetActive = true
        moveToSnippetStop(0)
    }

    /// Select stop `i`; past the last stop lands on `$0` and ends the session.
    private func moveToSnippetStop(_ i: Int) {
        guard snippetActive else { return }
        let len = (string as NSString).length
        if i >= snippetStops.count {
            let caret = min(snippetFinal, len)
            endSnippetSession()
            setSelectedRange(NSRange(location: caret, length: 0))
            return
        }
        snippetCurrent = max(0, i)
        let r = snippetStops[snippetCurrent].range
        let loc = min(r.location, len)
        let clamped = NSRange(location: loc, length: min(r.length, max(0, len - loc)))
        setSelectedRange(clamped)
        scrollRangeToVisible(clamped)
    }

    private func advanceSnippet(forward: Bool) {
        moveToSnippetStop(forward ? snippetCurrent + 1 : max(0, snippetCurrent - 1))
    }

    /// Teardown touches no text — only session bookkeeping is cleared.
    func endSnippetSession() {
        guard snippetActive else { return }
        snippetActive = false
        snippetStops = []
        snippetCurrent = -1
        snippetRange = NSRange(location: 0, length: 0)
        snippetFinal = 0
    }

    /// Re-flow stop / range bookkeeping for a pending edit (called from shouldChangeText, before
    /// the text mutates, so ranges are correct once it lands).
    private func adjustSnippet(edit: NSRange, replacementLength newLength: Int) {
        let s = edit.location, e = edit.location + edit.length
        let delta = newLength - edit.length
        for k in snippetStops.indices {
            var r = snippetStops[k].range
            let a = r.location, b = r.location + r.length
            if k == snippetCurrent {
                if e <= a { r.location += delta }               // before the active stop
                else if s > b { }                               // after it
                else if s >= a { r.length = max(0, r.length + delta) }   // inside → grow/shrink
                else { r.location = s; r.length = max(0, b + delta - s) } // spans its start
            } else {
                if e <= a { r.location += delta }
                else if s >= b { }                              // wholly after
                else { r.length = max(0, r.length + delta) }
            }
            snippetStops[k].range = r
        }
        let ra = snippetRange.location, rb = ra + snippetRange.length
        if e <= ra { snippetRange.location += delta }
        else if s > rb { }
        else { snippetRange.length = max(0, snippetRange.length + delta) }
        if e <= snippetFinal { snippetFinal += delta }
        else if s < snippetFinal { snippetFinal = s + newLength }
    }

    private func lspPosition(in text: String, at loc: Int) -> (Int, Int) {
        // loc is a UTF-16 offset (NSRange); LSP wants UTF-16 line/character too.
        let prefix = (text as NSString).substring(to: loc)
        let lines  = prefix.components(separatedBy: "\n")
        return (lines.count - 1, ((lines.last ?? "") as NSString).length)
    }

    // MARK: - VSCode-like editing

    private let indentUnit = "\t"   // Tab / auto-indent → real tab
    /// Number of spaces represented by one indentation level. Tab insertion remains a real tab;
    /// this width is used when existing space-indented text is dedented or backspaced.
    var indentationWidth = 2

    // Environments wrappable via `\env` + Tab (after picking the command from completion).
    private static let listEnvironments: Set<String> = ["itemize", "enumerate", "description"]
    private static let knownEnvironments = Set(LaTeXCommands.environments)

    // Editor shortcuts run through ShortcutStore (user-reassignable in Settings). performKeyEquivalent
    // catches command combos first — needed for ⌘. which macOS turns into Cancel before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept Cmd+Backspace before AppKit/menu key equivalents can route it around the text
        // command selectors. Shift does not change this operation; Option/Control retain stock word
        // deletion and other bindings.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !hasMarkedText(), event.keyCode == 51,
           flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            performIndentPreservingCommandDelete()
            return true
        }
        if !hasMarkedText(), let cmd = ShortcutStore.shared.command(for: event), runEditorCommand(cmd) {
            return true
        }
        // ⌘↩ open line below / ⇧⌘↩ open line above — wherever the caret sits on the line.
        if !hasMarkedText(), event.charactersIgnoringModifiers == "\r" {
            let f = event.modifierFlags
            if f.contains(.command) && !f.contains(.option) && !f.contains(.control) {
                openLine(above: f.contains(.shift)); return true
            }
        }
        // ⇧⌘K delete the caret line / every line the selection touches (VSCode).
        if !hasMarkedText(), event.keyCode == 40 {
            let f = event.modifierFlags
            if f.contains(.command) && f.contains(.shift) && !f.contains(.option) && !f.contains(.control) {
                deleteCurrentLines(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // Route the stock Find menu / ⌘F to our own find bar so the system find bar never opens.
    override func performFindPanelAction(_ sender: Any?) {
        guard let find = (delegate as? Coordinator)?.find else { return }
        switch (sender as? NSMenuItem)?.tag {
        case 2: find.next()      // NSFindPanelAction.next
        case 3: find.prev()      // NSFindPanelAction.previous
        default: find.show()     // showFindPanel + everything else
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // Insert a blank line above/below the caret's line (matching its indent) and move the caret onto it.
    private func openLine(above: Bool) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: selectedRange())
        let lineFull = ns.substring(with: lineRange)
        let hasNL = lineFull.hasSuffix("\n")
        let indent = leadingWhitespace(of: hasNL ? String(lineFull.dropLast()) : lineFull)
        let indentLen = (indent as NSString).length

        let at: Int, text: String, caret: Int
        if above {
            at = lineRange.location
            text = indent + "\n"
            caret = at + indentLen
        } else if hasNL {
            at = lineRange.location + lineRange.length      // start of next line
            text = indent + "\n"
            caret = at + indentLen
        } else {                                            // last line, no trailing newline
            at = lineRange.location + lineRange.length
            text = "\n" + indent
            caret = at + 1 + indentLen
        }
        _ = replace(range: NSRange(location: at, length: 0), with: text,
                    newSelection: NSRange(location: caret, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let cmd = ShortcutStore.shared.command(for: event), runEditorCommand(cmd) {
            return
        }
        // Esc ends an active snippet session (the popup, if open, swallows Esc before keyDown).
        if !hasMarkedText(), event.keyCode == 53, snippetActive { endSnippetSession(); return }
        // ⌥↑ / ⌥↓ move the line (or selected lines); ⌥⇧↑ / ⌥⇧↓ duplicate them.
        if !hasMarkedText() {
            let f = event.modifierFlags
            if f.contains(.option) && !f.contains(.command) && !f.contains(.control) {
                let dup = f.contains(.shift)
                if event.keyCode == 126 { dup ? duplicateLines(down: false) : moveLines(down: false); return }  // up
                if event.keyCode == 125 { dup ? duplicateLines(down: true)  : moveLines(down: true);  return }  // down
            }
        }
        super.keyDown(with: event)
    }

    // Duplicate the full lines spanned by the selection; caret/selection moves onto the new copy.
    private func duplicateLines(down: Bool) {
        let ns = string as NSString
        let block = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: block)
        let hasNL = text.hasSuffix("\n")
        let sel = selectedRange()

        let at: Int, inserted: String, shift: Int
        if down {
            at = block.location + block.length
            inserted = hasNL ? text : "\n" + text
            shift = hasNL ? block.length : block.length + 1
        } else {                                            // up: new copy takes the original span
            at = block.location
            inserted = hasNL ? text : text + "\n"
            shift = 0
        }
        _ = replace(range: NSRange(location: at, length: 0), with: inserted,
                    newSelection: NSRange(location: sel.location + shift, length: sel.length))
    }

    // Swap the full lines spanned by the selection with the adjacent line, keeping them selected.
    // Handles the doc's last line having no trailing newline (re-homes the \n so the end stays bare).
    private func moveLines(down: Bool) {
        let ns = string as NSString
        let block = ns.lineRange(for: selectedRange())
        let sel = selectedRange()
        let offset = sel.location - block.location   // selection start relative to the block

        let combined: NSRange, newText: String, newBlockStart: Int
        if down {
            let nextStart = block.location + block.length
            guard nextStart < ns.length else { NSSound.beep(); return }   // already last line
            let next = ns.lineRange(for: NSRange(location: nextStart, length: 0))
            combined = NSRange(location: block.location, length: block.length + next.length)
            var b = ns.substring(with: block)
            let n = ns.substring(with: next)
            if n.hasSuffix("\n") {
                newText = n + b
                newBlockStart = combined.location + (n as NSString).length
            } else {                                  // next is the bare last line: re-home block's \n
                b = String(b.dropLast())
                newText = n + "\n" + b
                newBlockStart = combined.location + (n as NSString).length + 1
            }
        } else {
            guard block.location > 0 else { NSSound.beep(); return }      // already first line
            let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            combined = NSRange(location: prev.location, length: prev.length + block.length)
            let b = ns.substring(with: block)
            var p = ns.substring(with: prev)
            if b.hasSuffix("\n") {
                newText = b + p
            } else {                                  // block is the bare last line: re-home prev's \n
                p = String(p.dropLast())
                newText = b + "\n" + p
            }
            newBlockStart = combined.location
        }
        replace(range: combined, with: newText,
                newSelection: NSRange(location: newBlockStart + offset, length: sel.length))
    }

    // Delete the full lines the selection touches as one undo step; caret lands at the same
    // column on the line that follows (clamped to its length), or the doc end.
    private func deleteCurrentLines() {
        let ns = string as NSString
        guard ns.length > 0 else { NSSound.beep(); return }
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let column = sel.location - block.location

        var range = block
        // Final line without a trailing newline: swallow the preceding \n so no blank line is left.
        if NSMaxRange(block) == ns.length, block.location > 0, ns.character(at: NSMaxRange(block) - 1) != 0x0A {
            range = NSRange(location: block.location - 1, length: block.length + 1)
        }
        let after = ns.replacingCharacters(in: range, with: "") as NSString
        let base = min(range.location, after.length)
        let line = after.lineRange(for: NSRange(location: base, length: 0))
        let hasNL = base < after.length && after.character(at: NSMaxRange(line) - 1) == 0x0A
        let content = line.length - (hasNL ? 1 : 0)
        let caret = min(base + min(column, content), after.length)
        replace(range: range, with: "", newSelection: NSRange(location: caret, length: 0))
    }

    /// Run an editor-owned command; false for commands handled elsewhere (build/sync via SwiftUI buttons).
    private func runEditorCommand(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .toggleComment: toggleComment(); return true
        case .showError:     toggleErrorPopoverAtCursor(); return true
        case .focusSidebar:  toggleSidebarFocus(); return true
        default:             return false
        }
    }

    /// ⌘⇧E: move first-responder focus between the editor and the file sidebar's outline view.
    /// performKeyEquivalent is dispatched window-wide (down the view tree, not the responder chain),
    /// so this fires no matter which pane has focus. AppKit-level because SwiftUI @FocusState
    /// cannot reliably *set* focus on a macOS 14 List.
    /// ponytail: firstDescendant picks the first NSTableView in the window — the sidebar, since the
    /// leading NavigationSplitView column precedes the problems panel in the view tree. If another
    /// table ever wins, scope the search to the split view's leading pane.
    private func toggleSidebarFocus() {
        guard let win = window, let content = win.contentView,
              let outline = Self.firstDescendant(of: content, where: { $0 is NSTableView })
        else { return }
        let fr = win.firstResponder as? NSView
        let inSidebar = fr != nil && (fr === outline || fr!.isDescendant(of: outline))
        win.makeFirstResponder(inSidebar ? self : outline)
    }

    static func firstDescendant(of root: NSView, where pred: (NSView) -> Bool) -> NSView? {
        if pred(root) { return root }
        for sub in root.subviews { if let f = firstDescendant(of: sub, where: pred) { return f } }
        return nil
    }

    // Tab: indent selection / wrap `\env` in begin-end / insert 2 spaces
    override func insertTab(_ sender: Any?) {
        if hasMarkedText() { super.insertTab(sender); return }
        if snippetActive { advanceSnippet(forward: true); return }
        if selectedRange().length > 0 { indentSelection(); return }
        if let (range, name) = environmentCommandBeforeCursor() {
            expandEnvironment(name, replacing: range); return
        }
        insertText(indentUnit, replacementRange: selectedRange())
    }

    // Shift+Tab: previous snippet stop / dedent
    override func insertBacktab(_ sender: Any?) {
        if hasMarkedText() { super.insertBacktab(sender); return }
        if snippetActive { advanceSnippet(forward: false); return }
        dedentSelection()
    }

    // Enter: continue `\item` list / keep current line's leading whitespace.
    // Shift+Enter routes to insertNewlineIgnoringFieldEditor (not overridden) → plain newline.
    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() { super.insertNewline(sender); return }
        let ns = string as NSString
        let loc = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let lineFull = ns.substring(with: lineRange)
        let hasNL = lineFull.hasSuffix("\n")
        let line = hasNL ? String(lineFull.dropLast()) : lineFull
        let indent = leadingWhitespace(of: line)

        // Comment line + Enter → continue the same `%` run (mirrors `\item`). Checked before the
        // list branch so a comment inside a list env continues the comment, not the `\item`.
        let rest = line.dropFirst(indent.count)
        if rest.first == "%" {
            let marker = String(rest.prefix { $0 == "%" })
            // Only continue when the caret sits after the marker; Enter before/at it stays a plain
            // newline+indent (the comment text moves down unmodified).
            if loc - lineRange.location >= indent.count + marker.count {
                let body = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if body.isEmpty {   // empty comment + Enter → drop the marker, exit the comment
                    replace(range: lineRange, with: indent + (hasNL ? "\n" : ""),
                            newSelection: NSRange(location: lineRange.location + (indent as NSString).length, length: 0))
                    return
                }
                super.insertNewline(sender)
                insertText(indent + marker + " ", replacementRange: selectedRange())
                return
            }
        }

        if inListEnvironment(at: loc) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\item") {
                let body = trimmed.dropFirst("\\item".count).trimmingCharacters(in: .whitespaces)
                if body.isEmpty {   // empty item + Enter → drop the marker, exit list
                    replace(range: lineRange, with: indent + (hasNL ? "\n" : ""),
                            newSelection: NSRange(location: lineRange.location + (indent as NSString).length, length: 0))
                    return
                }
                super.insertNewline(sender)
                insertText(indent + "\\item ", replacementRange: selectedRange())
                return
            }
        }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    // Typing a pair char: wrap selection / type over closer / auto-close. Else insert + completion.
    // Skip all custom handling while an IME is composing (marked text present).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !hasMarkedText() else { super.insertText(string, replacementRange: replacementRange); return }
        let wasApplying = isApplyingEdit; isApplyingEdit = true
        defer { isApplyingEdit = wasApplying }
        let pairs = ["{": "}", "(": ")", "[": "]", "$": "$"]
        let sel = selectedRange()
        if let open = string as? String, sel.length >= 0 {
            if sel.length > 0, let close = pairs[open] {          // wrap selection
                let inner = (self.string as NSString).substring(with: sel)
                if replace(range: sel, with: open + inner + close,
                           newSelection: NSRange(location: sel.location + 1, length: (inner as NSString).length)) {
                    return
                }
            } else if sel.length == 0, isCloser(open), nextChar() == open {   // type over
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                completion.close()
                return
            } else if sel.length == 0, let close = pairs[open], shouldAutoClose() {  // auto-close
                if replace(range: sel, with: open + close,
                           newSelection: NSRange(location: sel.location + 1, length: 0)) {
                    updateCompletionAfterEdit()   // `\usepackage{`, `\begin{`, `[` → popup
                    return
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        updateCompletionAfterEdit()
    }

    // Delete an empty auto-inserted pair as a unit: ( | ) ⌫ → ||. Backspace re-filters an open popup.
    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText() else { super.deleteBackward(sender); return }
        let wasApplying = isApplyingEdit; isApplyingEdit = true
        defer { isApplyingEdit = wasApplying }
        let pairs = ["{": "}", "(": ")", "[": "]", "$": "$"]
        let sel = selectedRange()
        var handled = false
        if sel.length == 0, sel.location > 0 {
            let prev = (string as NSString).substring(with: NSRange(location: sel.location - 1, length: 1))
            if let close = pairs[prev], nextChar() == close {
                replace(range: NSRange(location: sel.location - 1, length: 2), with: "",
                        newSelection: NSRange(location: sel.location - 1, length: 0))
                handled = true
            }
        }
        // Soft-tab backspace: inside leading spaces, erase one indent unit (back to the
        // previous tab stop) so indentation deletes as a unit, not space-by-space.
        if !handled, sel.length == 0, sel.location > 0 {
            let ns = string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let col = sel.location - lineStart
            let before = ns.substring(with: NSRange(location: lineStart, length: col))
            if col > 0, before.allSatisfy({ $0 == " " }) {
                let unit = max(1, indentationWidth)
                let remove = col - ((col - 1) / unit) * unit   // back to prev multiple of unit (≥1)
                replace(range: NSRange(location: sel.location - remove, length: remove), with: "",
                        newSelection: NSRange(location: sel.location - remove, length: 0))
                handled = true
            }
        }
        if !handled { super.deleteBackward(sender) }
        if completion.isVisible { updateCompletionAfterEdit() }
    }

    // Cmd+Delete is normally deleteToBeginningOfLine, but some AppKit key-binding setups emit
    // deleteToBeginningOfParagraph. Handle both without affecting Option+Delete/deleteWordBackward.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        if !deleteToIndentBoundary(useVisualLineStart: true) { super.deleteToBeginningOfLine(sender) }
    }

    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        if !deleteToIndentBoundary(useVisualLineStart: false) { super.deleteToBeginningOfParagraph(sender) }
    }

    /// Key-equivalent entry point for Cmd+Backspace. A selection keeps normal deletion semantics;
    /// a caret uses the indentation-preserving visual-line operation.
    private func performIndentPreservingCommandDelete() {
        let sel = selectedRange()
        guard sel.length > 0 else {
            _ = deleteToIndentBoundary(useVisualLineStart: true)
            return
        }

        let wasApplying = isApplyingEdit; isApplyingEdit = true
        defer { isApplyingEdit = wasApplying }
        _ = replace(range: sel, with: "", newSelection: NSRange(location: sel.location, length: 0))
        if completion.isVisible { updateCompletionAfterEdit() }
    }

    /// Delete line content before a caret while retaining all leading tabs/spaces. Returns false
    /// for selections and IME composition so AppKit preserves their standard behavior.
    private func deleteToIndentBoundary(useVisualLineStart: Bool) -> Bool {
        guard !hasMarkedText() else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }

        let ns = string as NSString
        let caret = min(sel.location, ns.length)
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let relevantStart = useVisualLineStart ? visualLineStart(at: caret) : lineStart
        var indentEnd = lineStart
        while indentEnd < ns.length {
            let c = ns.character(at: indentEnd)
            guard c == 0x20 || c == 0x09 else { break } // space / tab
            indentEnd += 1
        }
        // On or inside indentation (including a whitespace-only line), Cmd+Delete is a no-op.
        let deleteStart = max(relevantStart, indentEnd)
        guard caret > deleteStart else { return true }

        let wasApplying = isApplyingEdit; isApplyingEdit = true
        defer { isApplyingEdit = wasApplying }
        _ = replace(range: NSRange(location: deleteStart, length: caret - deleteStart), with: "",
                    newSelection: NSRange(location: deleteStart, length: 0))
        if completion.isVisible { updateCompletionAfterEdit() }
        return true
    }

    /// Character start of the current laid-out line fragment. This preserves stock Cmd+Delete
    /// behavior on soft-wrapped lines while still protecting the hard line's leading indentation.
    private func visualLineStart(at caret: Int) -> Int {
        guard let lm = layoutManager else { return caret }
        let nsLength = (string as NSString).length
        if caret == nsLength, (nsLength == 0 || (nsLength > 0 && (string as NSString).character(at: nsLength - 1) == 0x0A)) {
            return caret
        }
        let character = min(caret, max(0, nsLength - 1))
        let glyph = lm.glyphRange(forCharacterRange: NSRange(location: character, length: 0),
                                  actualCharacterRange: nil).location
        var fragmentGlyphRange = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphRange)
        return lm.characterIndexForGlyph(at: fragmentGlyphRange.location)
    }

    // Every committed edit re-flows active snippet stops. Skip while composing (marked text): the
    // edit is transient and setMarkedText already ended any session it touched.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok, snippetActive, !hasMarkedText(), let repl = replacementString {
            adjustSnippet(edit: affectedCharRange, replacementLength: (repl as NSString).length)
        }
        return ok
    }

    // IME composition inside the snippet would corrupt range bookkeeping → end the session (text
    // stays intact); safe degradation over corruption.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if snippetActive {
            let loc = replacementRange.location != NSNotFound ? replacementRange.location : self.selectedRange().location
            if loc >= snippetRange.location, loc <= NSMaxRange(snippetRange) { endSnippetSession() }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func resignFirstResponder() -> Bool {
        endSnippetSession()
        return super.resignFirstResponder()
    }

    // MARK: - Image paste (saves the image beside the .tex and inserts \includegraphics)

    /// Paste with an image on the pasteboard saves it into the document's folder (preferring an
    /// existing figures/ images/ fig/ subfolder) and inserts an \includegraphics for it.
    /// Plain text paste is untouched. Marked text (IME composition) always defers to super.
    override func paste(_ sender: Any?) {
        guard !hasMarkedText(), let baseDir = (delegate as? Coordinator)?.compiler?.fileURL?.deletingLastPathComponent(),
              let saved = Self.saveImageFromPasteboard(NSPasteboard.general, near: baseDir)
        else { super.paste(sender); return }

        // Path relative to the .tex dir, extension dropped (LaTeX resolves it).
        let rel = saved.path.hasPrefix(baseDir.path + "/")
            ? String(saved.path.dropFirst(baseDir.path.count + 1))
            : saved.lastPathComponent
        let relNoExt = (rel as NSString).deletingPathExtension
        let snippet = "\\includegraphics[width=0.8\\linewidth]{\(relNoExt)}"
        replace(range: selectedRange(), with: snippet,
                newSelection: NSRange(location: selectedRange().location + (snippet as NSString).length, length: 0))
    }

    /// Image file URL (Finder copy) or raw bitmap (screenshot) → saved file URL, else nil.
    /// Destination: an existing figures/ images/ fig/ subfolder of `baseDir`, else `baseDir` itself.
    private static func saveImageFromPasteboard(_ pb: NSPasteboard, near baseDir: URL) -> URL? {
        let dir = ["figures", "images", "fig"].map { baseDir.appending(path: $0) }
            .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? baseDir

        // 1. An image file copied from Finder → copy it across, keeping name/extension.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let src = urls.first(where: { imagePasteExts.contains($0.pathExtension.lowercased()) }) {
            let dest = uniqueImageURL(in: dir, base: src.deletingPathExtension().lastPathComponent, ext: src.pathExtension)
            return (try? FileManager.default.copyItem(at: src, to: dest)) != nil ? dest : nil
        }
        // 2. A raw bitmap (screenshot, browser image) → encode PNG. Text-only pasteboards (string
        //    present, no image data) fall through to nil so normal text paste is untouched.
        guard pb.string(forType: .string) == nil || pb.availableType(from: [.tiff, .png]) != nil,
              let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let dest = uniqueImageURL(in: dir, base: "image", ext: "png")
        return (try? png.write(to: dest)) != nil ? dest : nil
    }

    private static let imagePasteExts: Set<String> = ["png", "jpg", "jpeg", "pdf", "gif", "tiff", "tif", "bmp", "heic"]

    /// First free `base.ext` (then `base-1.ext`, …) in `dir`.
    private static func uniqueImageURL(in dir: URL, base: String, ext: String) -> URL {
        func make(_ n: Int) -> URL { dir.appending(path: n == 0 ? "\(base).\(ext)" : "\(base)-\(n).\(ext)") }
        var n = 0
        while FileManager.default.fileExists(atPath: make(n).path) { n += 1 }
        return make(n)
    }

    // MARK: helpers

    private func isAsciiLetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// `\env` (backslash + known environment name) immediately before the cursor.
    /// Returns range covering the backslash too, so wrapping replaces the whole token.
    private func environmentCommandBeforeCursor() -> (NSRange, String)? {
        let ns = string as NSString
        let loc = selectedRange().location
        var start = loc
        while start > 0, isAsciiLetter(ns.character(at: start - 1)) { start -= 1 }
        guard start < loc, start > 0, ns.character(at: start - 1) == 0x5C else { return nil }
        let word = ns.substring(with: NSRange(location: start, length: loc - start))
        guard Self.knownEnvironments.contains(word) else { return nil }
        return (NSRange(location: start - 1, length: loc - start + 1), word)
    }

    // MARK: pair / list helpers

    private func nextChar() -> String? {
        let ns = string as NSString
        let loc = selectedRange().location
        guard loc < ns.length else { return nil }
        return ns.substring(with: NSRange(location: loc, length: 1))
    }

    private func isCloser(_ s: String) -> Bool { ")]}$".contains(s) }

    /// Only auto-close when the next char is whitespace, a closer, or end-of-text —
    /// avoids turning `(word` into `()word`.
    private func shouldAutoClose() -> Bool {
        guard let n = nextChar() else { return true }
        return n == " " || n == "\n" || n == "\t" || ")]}$".contains(n)
    }

    private static let envRegex = try! NSRegularExpression(pattern: #"\\(begin|end)\s*\{\s*([A-Za-z*]+)\s*\}"#)

    /// True when the cursor sits inside an itemize/enumerate/description environment.
    private func inListEnvironment(at loc: Int) -> Bool {
        let prefix = (string as NSString).substring(to: loc)
        let pns = prefix as NSString
        var stack: [String] = []
        Self.envRegex.enumerateMatches(in: prefix, range: NSRange(location: 0, length: pns.length)) { m, _, _ in
            guard let m else { return }
            let kind = pns.substring(with: m.range(at: 1))
            let name = pns.substring(with: m.range(at: 2))
            if kind == "begin" { stack.append(name) }
            else if let idx = stack.lastIndex(of: name) { stack.removeSubrange(idx...) }
        }
        return Self.listEnvironments.contains(stack.last ?? "")
    }

    private func expandEnvironment(_ name: String, replacing range: NSRange) {
        let indent = leadingWhitespace(of: (string as NSString).substring(with:
            (string as NSString).lineRange(for: range)))
        let inner = indent + indentUnit
        let body  = Self.listEnvironments.contains(name) ? "\\item " : ""
        let prefix = "\\begin{\(name)}\n\(inner)\(body)"
        let full   = "\(prefix)\n\(indent)\\end{\(name)}"
        let cursor = range.location + (prefix as NSString).length
        replace(range: range, with: full, newSelection: NSRange(location: cursor, length: 0))
    }

    private func toggleComment() {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lineRange)
        let trailingNL = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNL { lines.removeLast() }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // All-empty selection: the normal path skips whitespace-only lines (silent no-op). Instead
        // append `% ` so the user can start typing; single line → caret right after the marker.
        if content.isEmpty {
            let newLines = lines.map { $0 + "% " }
            let newBlock = newLines.joined(separator: "\n") + (trailingNL ? "\n" : "")
            let selection = lines.count == 1
                ? NSRange(location: lineRange.location + ((lines[0] + "% ") as NSString).length, length: 0)
                : NSRange(location: lineRange.location, length: (newBlock as NSString).length)
            replace(range: lineRange, with: newBlock, newSelection: selection)
            return
        }
        let allCommented = !content.isEmpty && content.allSatisfy {
            $0.drop { $0 == " " || $0 == "\t" }.first == "%"
        }
        let newLines = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let indent = leadingWhitespace(of: line)
            var rest = String(line.dropFirst(indent.count))
            if allCommented {
                if rest.hasPrefix("% ") { rest.removeFirst(2) } else if rest.hasPrefix("%") { rest.removeFirst() }
            } else {
                rest = "% " + rest
            }
            return indent + rest
        }
        let newBlock = newLines.joined(separator: "\n") + (trailingNL ? "\n" : "")
        replace(range: lineRange, with: newBlock,
                newSelection: NSRange(location: lineRange.location, length: (newBlock as NSString).length))
    }

    private func indentSelection() {
        let ns = string as NSString
        let originalSelection = selectedRange()
        let lineRange = affectedLineRange(in: ns, for: originalSelection)
        let block = ns.substring(with: lineRange)
        let trailingNL = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNL { lines.removeLast() }

        let insertedLength = (indentUnit as NSString).length
        var oldOffset = 0
        var edits: [LinePrefixEdit] = []
        let newLines = lines.map { line -> String in
            edits.append(LinePrefixEdit(
                location: lineRange.location + oldOffset,
                removedLength: 0,
                insertedLength: insertedLength
            ))
            oldOffset += (line as NSString).length + 1
            return indentUnit + line
        }
        let newBlock = newLines.joined(separator: "\n") + (trailingNL ? "\n" : "")
        replace(range: lineRange, with: newBlock,
                newSelection: remapSelection(originalSelection, through: edits))
    }

    private func dedentSelection() {
        let ns = string as NSString
        let originalSelection = selectedRange()
        let lineRange = affectedLineRange(in: ns, for: originalSelection)
        let block = ns.substring(with: lineRange)
        let trailingNL = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNL { lines.removeLast() }

        var oldOffset = 0
        var edits: [LinePrefixEdit] = []
        let newLines = lines.map { line -> String in
            let source = line as NSString
            let remove = self.dedentPrefixLength(in: source)
            if remove > 0 {
                edits.append(LinePrefixEdit(
                    location: lineRange.location + oldOffset,
                    removedLength: remove,
                    insertedLength: 0
                ))
            }
            oldOffset += source.length + 1
            return source.substring(from: remove)
        }
        let newBlock = newLines.joined(separator: "\n") + (trailingNL ? "\n" : "")
        replace(range: lineRange, with: newBlock,
                newSelection: remapSelection(originalSelection, through: edits))
    }

    /// One indentation level is one leading tab, otherwise up to the configured number of
    /// leading spaces. A spaces-then-tab prefix removes only the spaces on this invocation.
    private func dedentPrefixLength(in line: NSString) -> Int {
        guard line.length > 0 else { return 0 }
        if line.character(at: 0) == 0x09 { return 1 }
        var count = 0
        while count < min(max(1, indentationWidth), line.length), line.character(at: count) == 0x20 {
            count += 1
        }
        return count
    }

    private struct LinePrefixEdit {
        let location: Int
        let removedLength: Int
        let insertedLength: Int
    }

    /// Return the complete lines touched by the selection's characters. In particular, a
    /// selection ending exactly at the next line's first character does not include that line.
    private func affectedLineRange(in text: NSString, for selection: NSRange) -> NSRange {
        guard selection.length > 0 else { return text.lineRange(for: selection) }
        let firstLine = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lastLine = text.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
        return NSRange(location: firstLine.location,
                       length: NSMaxRange(lastLine) - firstLine.location)
    }

    /// Keep the selection attached to the originally selected text while line prefixes change.
    /// At an inserted prefix, the leading selection edge stays after it and the trailing edge
    /// stays before it; insertions on interior lines naturally remain inside the selection.
    private func remapSelection(_ selection: NSRange, through edits: [LinePrefixEdit]) -> NSRange {
        let start = remapLocation(selection.location, through: edits,
                                  afterInsertionAtBoundary: true)
        let end = remapLocation(NSMaxRange(selection), through: edits,
                                afterInsertionAtBoundary: false)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func remapLocation(_ location: Int, through edits: [LinePrefixEdit],
                               afterInsertionAtBoundary: Bool) -> Int {
        var delta = 0
        for edit in edits {
            let editEnd = edit.location + edit.removedLength
            if location < edit.location { break }

            if edit.removedLength == 0, location == edit.location {
                return edit.location + delta
                    + (afterInsertionAtBoundary ? edit.insertedLength : 0)
            }
            if location <= editEnd {
                return edit.location + delta + edit.insertedLength
            }
            delta += edit.insertedLength - edit.removedLength
        }
        return location + delta
    }

    @discardableResult
    private func replace(range: NSRange, with str: String, newSelection: NSRange) -> Bool {
        guard shouldChangeText(in: range, replacementString: str) else { return false }
        textStorage?.replaceCharacters(in: range, with: str)
        didChangeText()
        setSelectedRange(newSelection)
        return true
    }

    // MARK: - Error line highlight + popover

    private let errorPopover = ErrorPopover()
    private let imagePopover = ImagePreviewPopover()

    private static let includeGraphicsRegex = try! NSRegularExpression(
        pattern: #"\\includegraphics\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)

    /// Loadable image file referenced by `\includegraphics{...}` on the cursor's line, else nil.
    /// ponytail: resolves relative to the .tex dir only — no `\graphicspath`. Add if a project needs it.
    private func imageURLOnCursorLine() -> URL? {
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: loc, length: 0)))
        guard let m = Self.includeGraphicsRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line),
              let baseDir = (delegate as? Coordinator)?.compiler?.fileURL?.deletingLastPathComponent()
        else { return nil }
        let raw = String(line[r]).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let fm = FileManager.default
        let direct = baseDir.appendingPathComponent(raw)
        if fm.fileExists(atPath: direct.path) { return direct }
        if direct.pathExtension.isEmpty {   // LaTeX resolves the extension itself
            for ext in ["pdf", "png", "jpg", "jpeg", "eps", "gif", "tiff", "tif", "bmp"] {
                let u = direct.appendingPathExtension(ext)
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// 1-based source line → error message. Lines get a light-red background; hover / ⌘. shows the message.
    var errorInfo: [Int: String] = [:] {
        didSet { if errorInfo != oldValue { needsDisplay = true; if errorInfo[errorPopover.currentLine ?? -1] == nil { errorPopover.close() } } }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Current-line highlight (caret only, no range) — drawn under the red error shading.
        if selectedRange().length == 0, let r = currentLineFragmentRect() {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.12).setFill()
            r.fill()
        }
        // Keep the active environment local and legible: only its two names get a subtle pill,
        // leaving selections, find hits, and the body of nested environments unobscured.
        if let pair = activeEnvironmentPairs.last {
            drawActiveEnvironmentName(pair.beginNameRange, depth: pair.depth, dirtyRect: rect)
            drawActiveEnvironmentName(pair.endNameRange, depth: pair.depth, dirtyRect: rect)
        }
        guard !errorInfo.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        for line in errorInfo.keys {
            var r = lineRect(line, lm: lm, tc: tc)
            guard r != .zero else { continue }
            r.origin.x = 0
            r.size.width = bounds.width
            r.fill()
        }
    }

    private func drawActiveEnvironmentName(_ characterRange: NSRange, depth: Int, dirtyRect: NSRect) {
        guard characterRange.length > 0,
              NSMaxRange(characterRange) <= (string as NSString).length,
              let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let visibleCharacters = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard NSIntersectionRange(characterRange, visibleCharacters).length > 0 else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        var nameRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        nameRect.origin.x += origin.x
        nameRect.origin.y += origin.y
        nameRect = nameRect.insetBy(dx: -2.5, dy: 0.5)
        guard nameRect.intersects(dirtyRect) else { return }

        let color = Self.pairColor(forDepth: depth)
        color.withAlphaComponent(0.14).setFill()
        color.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath(roundedRect: nameRect, xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        path.fill()
        path.stroke()
    }

    /// Full-width rect of the caret's line fragment (view coordinates), for the current-line highlight.
    private func currentLineFragmentRect() -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        var rect: NSRect
        if loc >= ns.length {                                       // caret at end of document
            if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
                rect = lm.extraLineFragmentRect
            } else {
                let g = lm.glyphRange(forCharacterRange: NSRange(location: ns.length - 1, length: 1),
                                      actualCharacterRange: nil).location
                rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            }
        } else {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 0),
                                  actualCharacterRange: nil).location
            rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
    }

    /// Bounding rect of a 1-based source line in view coordinates.
    private func lineRect(_ line: Int, lm: NSLayoutManager, tc: NSTextContainer) -> NSRect {
        guard let cr = LaTeXEditorView.range(ofLine: line, in: string) else { return .zero }
        let gr = lm.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: gr, in: tc)
        if r.height < 1 {
            r.size.height = lm.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        }
        let o = textContainerOrigin
        r.origin.x += o.x; r.origin.y += o.y
        return r
    }

    /// ⌘. → toggle the error popover for the cursor's line; if the line has no error but
    /// references an image, toggle an image-preview popover instead.
    private func toggleErrorPopoverAtCursor() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let line = ns.substring(to: loc).components(separatedBy: "\n").count

        if let msg = errorInfo[line] {
            imagePopover.close()
            if errorPopover.isShown, errorPopover.currentLine == line { errorPopover.close() }
            else { errorPopover.show(message: msg, line: line, lineRect: lineRect(line, lm: lm, tc: tc), in: self) }
            return
        }
        if let url = imageURLOnCursorLine(), let img = NSImage(contentsOf: url) {
            errorPopover.close()
            if imagePopover.isShown, imagePopover.currentLine == line { imagePopover.close() }
            else { imagePopover.show(image: img, line: line, lineRect: lineRect(line, lm: lm, tc: tc), in: self) }
            return
        }
        NSSound.beep()
    }

    // MARK: - Scroll sync

    /// 1-based source line at the vertical center of the visible editor area, plus where within
    /// that (possibly soft-wrapped) line the center sits (0 = its first visual row, 1 = its last).
    /// The fraction picks the matching typeset row among SyncTeX's per-row records, so a long
    /// paragraph written as one source line still centers PDF-row ↔ editor-row, not paragraph start.
    func lineAtVisibleCenter() -> (line: Int, fraction: CGFloat)? {
        guard let lm = layoutManager, let tc = textContainer, let scroll = enclosingScrollView else { return nil }
        let o = textContainerOrigin
        let centerY = scroll.documentVisibleRect.midY
        let glyph = lm.glyphIndex(for: NSPoint(x: 4 - o.x, y: centerY - o.y), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let ns = string as NSString
        guard char <= ns.length else { return nil }
        let line = ns.substring(to: char).components(separatedBy: "\n").count

        var fraction: CGFloat = 0.5
        if let cr = LaTeXEditorView.range(ofLine: line, in: string) {
            let gr = lm.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: gr, in: tc)
            r.origin.y += o.y
            if r.height > 1 { fraction = min(max((centerY - r.minY) / r.height, 0), 1) }
        }
        return (line, fraction)
    }

    /// Smoothly scroll so a 1-based line sits at the vertical center, clamped to the document.
    func centerLine(_ line: Int) {
        guard let lm = layoutManager, let tc = textContainer, let scroll = enclosingScrollView,
              let cr = LaTeXEditorView.range(ofLine: line, in: string) else { return }
        let gr = lm.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: gr, in: tc)
        r.origin.y += textContainerOrigin.y
        let visH = scroll.documentVisibleRect.height
        let y = min(max(r.midY - visH / 2, 0), max(0, bounds.height - visH))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// MARK: - Syntax Highlighter

private enum Syntax {
    struct Rule { let pattern: NSRegularExpression; let color: NSColor }

    static let rules: [Rule] = [
        rule(#"\\[a-zA-Z@*]+"#,    .systemBlue),          // \commands
        rule(#"\$[^$\n]*?\$"#,      .systemBrown),         // $inline math$
        rule(#"\$\$[\s\S]*?\$\$"#, .systemBrown),         // $$display$$
        rule(#"%[^\n]*"#,           .secondaryLabelColor), // % comments (last = override)
    ]

    private static func rule(_ p: String, _ c: NSColor) -> Rule {
        Rule(pattern: try! NSRegularExpression(pattern: p), color: c)
    }

    static func apply(to lm: NSLayoutManager, string: String,
                      structureSnapshot: LaTeXStructureSnapshot) {
        guard string.count < 300_000 else { return }
        let full = NSRange(string.startIndex..., in: string)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        for rule in rules {
            rule.pattern.enumerateMatches(in: string, range: full) { m, _, _ in
                guard let m else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: rule.color, forCharacterRange: m.range)
            }
        }
        // Apply pair colors after ordinary syntax so only parsed environment names override the
        // token palette. Commands, braces, comments, and ignored/verbatim regions stay untouched.
        for pair in structureSnapshot.pairs {
            let color = LaTeXTextView.pairColor(forDepth: pair.depth)
            for range in [pair.beginNameRange, pair.endNameRange]
            where range.length > 0 && NSMaxRange(range) <= full.length {
                lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            }
        }
        let issueUnderline = NSUnderlineStyle.single.union(.patternDot).rawValue
        for issue in structureSnapshot.issues
        where issue.range.length > 0 && NSMaxRange(issue.range) <= full.length {
            lm.addTemporaryAttribute(.underlineStyle, value: issueUnderline,
                                     forCharacterRange: issue.range)
            lm.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed,
                                     forCharacterRange: issue.range)
        }
    }
}

// MARK: - NSViewRepresentable

struct LaTeXEditorView: NSViewRepresentable {
    @Binding var text: String
    var texLabClient: TexLabClient?
    var compiler: LaTeXCompiler?
    var errorMessages: [Int: String] = [:]
    var selectReq: SelectLineRequest?    // diffed so updateNSView runs on inverse search / scroll-sync
    var scrollReq: SelectLineRequest?
    var tabWidth: Int = 2                 // tab render width in spaces (Settings)
    var fontScale: Double = 1.0           // editor zoom (⌘+/⌘-/⌘0 via FontScale)
    var find: FindController?             // in-file find/replace bar (⌘F)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Monospaced editor font at the current zoom; the gutter and tab width follow it.
    static func editorFont(scale: Double) -> NSFont {
        .monospacedSystemFont(ofSize: FontScale.baseSize * CGFloat(scale), weight: .regular)
    }

    /// Paragraph style that renders a tab at `tabWidth` space-widths (no wide default tab stops).
    private func tabParagraphStyle(font: NSFont) -> NSParagraphStyle {
        let spaceW = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = spaceW * CGFloat(max(1, tabWidth))
        return style
    }

    /// NSRange of a 1-based line, for SyncTeX inverse-search selection.
    static func range(ofLine line: Int, in string: String) -> NSRange? {
        let ns = string as NSString
        var idx = 0, current = 1
        while current < line {
            let nl = ns.range(of: "\n", range: NSRange(location: idx, length: ns.length - idx))
            guard nl.location != NSNotFound else { return nil }
            idx = nl.location + 1
            current += 1
        }
        let end = ns.range(of: "\n", range: NSRange(location: idx, length: ns.length - idx))
        let lineEnd = end.location != NSNotFound ? end.location : ns.length
        return NSRange(location: idx, length: max(0, lineEnd - idx))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true

        let tv = LaTeXTextView()
        tv.isEditable      = true
        tv.isSelectable    = true
        tv.allowsUndo      = true
        tv.isRichText      = false
        tv.usesFontPanel   = false
        tv.usesRuler       = true
        let editorFont     = LaTeXEditorView.editorFont(scale: fontScale)
        tv.font            = editorFont
        tv.indentationWidth = max(1, tabWidth)
        // Render a tab at `tabWidth` space-widths instead of the wide default tab stop.
        let tabStyle = tabParagraphStyle(font: editorFont)
        tv.defaultParagraphStyle = tabStyle
        tv.typingAttributes[.paragraphStyle] = tabStyle
        context.coordinator.tabStyle = tabStyle
        context.coordinator.appliedTabWidth = tabWidth
        context.coordinator.appliedFontScale = fontScale
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled             = false
        tv.isContinuousSpellCheckingEnabled     = false
        tv.isAutomaticTextCompletionEnabled     = false
        tv.textContainerInset        = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable     = true
        tv.isHorizontallyResizable   = false
        tv.autoresizingMask          = .width
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator

        // Seed the initial buffer and its structure before the first SwiftUI update pass.
        tv.string = text
        tv.textStorage?.addAttribute(.paragraphStyle, value: tabStyle,
            range: NSRange(location: 0, length: (text as NSString).length))
        tv.refreshStructureHighlighting()

        scrollView.documentView = tv
        context.coordinator.textView = tv
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.editorScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Quick-open content hit → jump to line when this document is already open in some window.
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.handleJumpNotification(_:)),
                                               name: .iTexJumpToLine, object: nil)

        // Line-number gutter in the vertical ruler.
        scrollView.hasVerticalRuler   = true
        scrollView.hasHorizontalRuler = false
        scrollView.rulersVisible      = true
        let ruler = LineNumberRuler(textView: tv, scrollView: scrollView)
        scrollView.verticalRulerView  = ruler
        context.coordinator.lineRuler = ruler
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? LaTeXTextView else { return }
        context.coordinator.texLabClient = texLabClient   // keep in sync
        context.coordinator.compiler = compiler
        tv.indentationWidth = max(1, tabWidth)
        let scaleChanged = context.coordinator.appliedFontScale != fontScale
        if scaleChanged || context.coordinator.appliedTabWidth != tabWidth {   // Settings changed font size / tab width
            let font = LaTeXEditorView.editorFont(scale: fontScale)
            if scaleChanged { tv.font = font }                                 // applies to the whole text storage
            let style = tabParagraphStyle(font: font)                          // tab width is space-relative → recompute
            tv.defaultParagraphStyle = style
            tv.typingAttributes[.paragraphStyle] = style
            tv.typingAttributes[.font] = font
            context.coordinator.tabStyle = style
            context.coordinator.appliedTabWidth = tabWidth
            context.coordinator.appliedFontScale = fontScale
            tv.textStorage?.addAttribute(.paragraphStyle, value: style,
                range: NSRange(location: 0, length: (tv.string as NSString).length))
            context.coordinator.lineRuler?.refresh()
        }
        if tv.string != text {
            tv.endSnippetSession()   // outside edit replaced the buffer → any session's ranges are void
            tv.string = text
            if let style = context.coordinator.tabStyle {   // string setter drops paragraph style; reapply
                tv.textStorage?.addAttribute(.paragraphStyle, value: style,
                    range: NSRange(location: 0, length: (text as NSString).length))
            }
            tv.refreshStructureHighlighting()
            context.coordinator.findMatchesStale = true   // ranges shifted → recompute find on next pass
            context.coordinator.lineRuler?.refresh()      // direct string set posts no didChange notification
        }
        tv.errorInfo = errorMessages      // light-red background + hover/⌘. message popover
        // SyncTeX inverse search (⌘-click): select the requested source line once per request.
        if let req = compiler?.selectLineRequest, req.token != context.coordinator.lastSelectToken {
            context.coordinator.lastSelectToken = req.token
            if let range = LaTeXEditorView.range(ofLine: req.line, in: tv.string) {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
                tv.window?.makeFirstResponder(tv)
            }
        }
        // Scroll-sync (PDF → editor): center the line without touching the selection.
        if let req = compiler?.scrollToLineRequest, req.token != context.coordinator.lastScrollLineToken {
            context.coordinator.lastScrollLineToken = req.token
            compiler?.beginSyncCooldown()
            tv.centerLine(req.line)
        }
        // Quick-open content hit into a freshly-opened document: consume its parked jump once the
        // text is in place (take() removes it, so re-runs of updateNSView don't re-jump).
        if let url = compiler?.fileURL, let line = PendingJump.shared.take(url) {
            context.coordinator.performJump(to: line)
        }
        context.coordinator.bindFind(find)
        context.coordinator.applyFind(find)
    }
}

// MARK: - Coordinator

final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: LaTeXEditorView
    var texLabClient: TexLabClient?
    var compiler: LaTeXCompiler?
    weak var textView: LaTeXTextView?
    var lastSelectToken = -1
    var lastScrollLineToken = -1
    var tabStyle: NSParagraphStyle?
    var appliedTabWidth = -1
    var appliedFontScale = -1.0
    weak var lineRuler: LineNumberRuler?
    private var scrollWork: DispatchWorkItem?

    // Find/replace state (single source of truth is the FindController; these mirror it for logic).
    var find: FindController?
    private var findSubscription: AnyCancellable?
    private var findMatches: [NSRange] = []
    private var findCurrent = 0
    var findMatchesStale = false
    private var findLastVisible = false
    private var findLastQuery = ""
    private var findLastCase = false
    private var findLastNav = 0
    private var findLastReplaceToken = 0

    init(_ parent: LaTeXEditorView) {
        self.parent = parent
        self.texLabClient = parent.texLabClient
        self.compiler = parent.compiler
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // Quick-open content hit: select the 1-based line and scroll it into view (mirrors the
    // SyncTeX inverse-search select path).
    func performJump(to line: Int) {
        guard let tv = textView, let range = LaTeXEditorView.range(ofLine: line, in: tv.string) else { return }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.window?.makeFirstResponder(tv)
    }

    // A quick-open content hit was opened elsewhere; if it's this window's file, jump to the line.
    @MainActor @objc func handleJumpNotification(_ note: Notification) {
        guard let url = note.userInfo?["url"] as? URL,
              let line = note.userInfo?["line"] as? Int,
              url.standardizedFileURL == compiler?.fileURL?.standardizedFileURL else { return }
        _ = PendingJump.shared.take(url)   // clear the parked jump so it isn't consumed twice
        performJump(to: line)
    }

    // Scroll-sync (editor → PDF): center the PDF on the editor's center line, debounced.
    @MainActor @objc func editorScrolled() {
        guard compiler?.scrollSyncEnabled == true, compiler?.inSyncCooldown == false else { return }
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let hit = self.textView?.lineAtVisibleCenter() else { return }
            Task { @MainActor in await self.compiler?.forwardSearch(line: hit.line, fraction: hit.fraction) }
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        parent.text = tv.string
        (tv as? LaTeXTextView)?.refreshStructureHighlighting()
        findMatchesStale = true   // ranges shifted; recompute on the next applyFind pass
    }

    // Track cursor line for SyncTeX; dismiss the completion popup on a non-edit caret move.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        (tv as? LaTeXTextView)?.handleSelectionChange()
        guard let compiler else { return }
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        compiler.cursorLine = ns.substring(to: loc).components(separatedBy: "\n").count
    }

    // MARK: - Find / replace
    //
    // Find highlights live as *temporary* `.backgroundColor` attributes on the layout manager.
    // Syntax highlighting (Syntax.apply) only touches temporary `.foregroundColor` — it removes
    // and re-adds that key alone and never clears `.backgroundColor` — so the two passes are
    // orthogonal: a syntax re-run on every edit leaves find highlights intact, and the find pass
    // never disturbs the token colors. Only the match *ranges* go stale on edits, so a text
    // change flags `findMatchesStale` and the next applyFind recomputes + repaints them.

    /// Observe the controller directly: SwiftUI skips updateNSView when the representable's
    /// stored properties are unchanged (the controller is the same reference), so bar-driven
    /// state changes (query typing, Esc close, nav) would otherwise never reach applyFind.
    func bindFind(_ find: FindController?) {
        if self.find !== find {
            self.find = find
            findSubscription = find?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyFind(self?.find) }
            }
        }
    }

    func applyFind(_ find: FindController?) {
        guard let find, let tv = textView else { return }

        // Replace requests arrive as a bumped replaceToken; handle and return so the normal
        // find/nav pass doesn't also run.
        if find.replaceToken != findLastReplaceToken {
            findLastReplaceToken = find.replaceToken
            guard find.isVisible, !find.query.isEmpty else { return }
            if find.replaceAllRequested { replaceAllFind(tv, find) } else { replaceOnceFind(tv, find) }
            return
        }

        let becameVisible = find.isVisible && !findLastVisible
        let queryChanged  = find.query != findLastQuery || find.caseSensitive != findLastCase
        let navChanged    = find.navToken != findLastNav
        let wasVisible    = findLastVisible
        findLastVisible = find.isVisible
        findLastQuery   = find.query
        findLastCase    = find.caseSensitive
        findLastNav     = find.navToken

        guard find.isVisible else {
            if wasVisible {                                   // bar closed → clean up + hand focus back
                clearFindHighlights(tv)
                publishFind(find)
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
            return
        }
        if becameVisible { prefillFind(find, tv) }
        guard becameVisible || queryChanged || navChanged || findMatchesStale else { return }
        guard !find.query.isEmpty else {
            findMatches = []; findCurrent = 0
            clearFindHighlights(tv); publishFind(find); return
        }

        if becameVisible || queryChanged || findMatchesStale {
            recomputeFind(tv, query: find.query, caseSensitive: find.caseSensitive)
            if becameVisible || queryChanged {                // land on the match at/after the caret
                let caret = tv.selectedRange().location
                findCurrent = findMatches.firstIndex(where: { $0.location >= caret }) ?? 0
            }
        }
        if navChanged, !findMatches.isEmpty {
            findCurrent = find.backwards ? (findCurrent - 1 + findMatches.count) % findMatches.count
                                         : (findCurrent + 1) % findMatches.count
        }
        findCurrent = findMatches.isEmpty ? 0 : min(findCurrent, findMatches.count - 1)
        highlightFind(tv)
        // Don't yank the viewport on a bare text edit (matchesStale only) — that would fight a
        // caret the user is driving in the editor with the bar open.
        if (becameVisible || queryChanged || navChanged), !findMatches.isEmpty { jumpToCurrentFind(tv) }
        publishFind(find)
    }

    private func recomputeFind(_ tv: NSTextView, query: String, caseSensitive: Bool) {
        findMatches = []
        findMatchesStale = false
        findLastQuery = query
        findLastCase = caseSensitive
        guard !query.isEmpty else { return }
        let s = tv.string as NSString
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var loc = 0
        while loc < s.length {
            let r = s.range(of: query, options: opts, range: NSRange(location: loc, length: s.length - loc))
            if r.location == NSNotFound { break }
            findMatches.append(r)
            loc = r.location + max(1, r.length)
        }
    }

    private func highlightFind(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for (i, r) in findMatches.enumerated() where NSMaxRange(r) <= full.length {
            let color = (i == findCurrent)
                ? NSColor.findHighlightColor
                : NSColor.findHighlightColor.withAlphaComponent(0.35)
            lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r)
        }
    }

    private func clearFindHighlights(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }

    private func jumpToCurrentFind(_ tv: NSTextView) {
        guard findCurrent < findMatches.count else { return }
        let r = findMatches[findCurrent]
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
    }

    /// Replace the current match (literal), then advance so the next match becomes current.
    private func replaceOnceFind(_ tv: NSTextView, _ find: FindController) {
        if findMatchesStale || findMatches.isEmpty {
            recomputeFind(tv, query: find.query, caseSensitive: find.caseSensitive)
        }
        guard !findMatches.isEmpty, findCurrent < findMatches.count else { publishFind(find); return }
        let r = findMatches[findCurrent]
        replaceRange(tv, r, with: find.replacement)
        recomputeFind(tv, query: find.query, caseSensitive: find.caseSensitive)
        let after = r.location + (find.replacement as NSString).length
        findCurrent = findMatches.firstIndex(where: { $0.location >= after }) ?? 0
        findCurrent = findMatches.isEmpty ? 0 : min(findCurrent, findMatches.count - 1)
        highlightFind(tv)
        if !findMatches.isEmpty { jumpToCurrentFind(tv) }
        publishFind(find)
    }

    /// Replace every match in ONE undo step (reversed so earlier ranges stay valid).
    private func replaceAllFind(_ tv: NSTextView, _ find: FindController) {
        if findMatchesStale || findMatches.isEmpty {
            recomputeFind(tv, query: find.query, caseSensitive: find.caseSensitive)
        }
        guard !findMatches.isEmpty else { publishFind(find); return }
        tv.undoManager?.beginUndoGrouping()
        for r in findMatches.reversed() { replaceRange(tv, r, with: find.replacement) }
        tv.undoManager?.endUndoGrouping()
        recomputeFind(tv, query: find.query, caseSensitive: find.caseSensitive)
        findCurrent = 0
        highlightFind(tv)
        publishFind(find)
    }

    /// Edit through shouldChangeText/didChangeText so undo, syntax re-highlight, and the LSP
    /// didChange all fire — bypassing LaTeXTextView.insertText's pair/auto-close handling.
    private func replaceRange(_ tv: NSTextView, _ range: NSRange, with str: String) {
        guard tv.shouldChangeText(in: range, replacementString: str) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: str)
        tv.didChangeText()
    }

    /// Prefill the query from a non-empty single-line editor selection (deferred: the write can't
    /// happen during the SwiftUI view update that drives this pass).
    private func prefillFind(_ find: FindController, _ tv: NSTextView) {
        let sel = tv.selectedRange()
        guard sel.length > 0 else { return }
        let s = (tv.string as NSString).substring(with: sel)
        guard !s.contains("\n") else { return }
        DispatchQueue.main.async { find.query = s }
    }

    /// Mirror match state onto the controller for the bar's counter (deferred + deduped to avoid
    /// mutating observed state during the view update).
    private func publishFind(_ find: FindController) {
        let m = findMatches, c = findCurrent
        guard find.matches != m || find.currentIndex != c else { return }
        DispatchQueue.main.async {
            if find.matches != m { find.matches = m }
            if find.currentIndex != c { find.currentIndex = c }
        }
    }
}

#else
// MARK: - iOS (plain UITextView, no texlab)

import UIKit

struct LaTeXEditorView: UIViewRepresentable {
    @Binding var text: String
    var texLabClient: TexLabClient? = nil   // unused on iOS
    var compiler: LaTeXCompiler? = nil      // unused on iOS (no SyncTeX subprocess)
    var errorMessages: [Int: String] = [:]  // unused on iOS
    var selectReq: SelectLineRequest? = nil
    var scrollReq: SelectLineRequest? = nil
    var tabWidth: Int = 2                    // unused on iOS
    var fontScale: Double = 1.0              // unused on iOS
    var find: FindController? = nil          // unused on iOS

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        tv.autocorrectionType  = .no
        tv.autocapitalizationType = .none
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
    }

    func makeCoordinator() -> UICoordinator { UICoordinator(self) }

    final class UICoordinator: NSObject, UITextViewDelegate {
        var parent: LaTeXEditorView
        init(_ p: LaTeXEditorView) { parent = p }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
#endif
