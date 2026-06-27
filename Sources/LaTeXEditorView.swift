import SwiftUI

#if os(macOS)
import AppKit

// MARK: - NSTextView subclass

final class LaTeXTextView: NSTextView {
    enum CompletionContext { case command, brace, option, none }

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
        let server = (delegate as? Coordinator)?.texLabClient?.latestCompletions.map(\.label) ?? []
        let raw: [String]
        switch ctx {
        case .command, .none:
            raw = server.map { "\\" + $0 } + LaTeXCommands.environments.map { "\\" + $0 } + LaTeXCommands.all
        case .brace:
            raw = server
        case .option:
            raw = LaTeXCommands.optionKeys
        }
        var seen = Set<String>(), out: [CompletionItem] = []
        for s in raw where s.hasPrefix(prefix) && s != prefix && seen.insert(s).inserted {
            out.append(CompletionItem(display: s, insert: s))
        }
        return out
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
    func handleSelectionChange() {
        errorPopover.close()
        if !isApplyingEdit, completion.isVisible { completion.close() }
    }

    /// Accept the highlighted item. A wrappable environment expands straight to
    /// `\begin{env}…\end{env}` (one step — no intermediate `\env` then Tab).
    func acceptCompletion(_ item: CompletionItem) {
        if item.insert.hasPrefix("\\"), Self.knownEnvironments.contains(String(item.insert.dropFirst())) {
            expandEnvironment(String(item.insert.dropFirst()), replacing: completionWordRange)
            return
        }
        replace(range: completionWordRange, with: item.insert,
                newSelection: NSRange(location: completionWordRange.location + (item.insert as NSString).length, length: 0))
    }

    private func lspPosition(in text: String, at loc: Int) -> (Int, Int) {
        // loc is a UTF-16 offset (NSRange); LSP wants UTF-16 line/character too.
        let prefix = (text as NSString).substring(to: loc)
        let lines  = prefix.components(separatedBy: "\n")
        return (lines.count - 1, ((lines.last ?? "") as NSString).length)
    }

    // MARK: - VSCode-like editing

    private let indentUnit = "  "   // Tab → 2 spaces

    // Environments wrappable via `\env` + Tab (after picking the command from completion).
    private static let listEnvironments: Set<String> = ["itemize", "enumerate", "description"]
    private static let knownEnvironments = Set(LaTeXCommands.environments)

    // ⌘. → error popover. Caught here (not keyDown) because macOS turns ⌘. into Cancel before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "." {
            toggleErrorPopoverAtCursor()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // ⌘/ → toggle line comment
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "/" {
            toggleComment()
            return
        }
        super.keyDown(with: event)
    }

    // Tab: indent selection / wrap `\env` in begin-end / insert 2 spaces
    override func insertTab(_ sender: Any?) {
        if hasMarkedText() { super.insertTab(sender); return }
        if selectedRange().length > 0 { indentSelection(); return }
        if let (range, name) = environmentCommandBeforeCursor() {
            expandEnvironment(name, replacing: range); return
        }
        insertText(indentUnit, replacementRange: selectedRange())
    }

    // Shift+Tab: dedent
    override func insertBacktab(_ sender: Any?) {
        if hasMarkedText() { super.insertBacktab(sender); return }
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
        if !handled { super.deleteBackward(sender) }
        if completion.isVisible { updateCompletionAfterEdit() }
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
        rewriteSelectedLines { self.indentUnit + $0 }
    }

    private func dedentSelection() {
        rewriteSelectedLines { line in
            var l = Substring(line), removed = 0
            while removed < self.indentUnit.count, l.first == " " { l.removeFirst(); removed += 1 }
            if removed == 0, l.first == "\t" { l.removeFirst() }
            return String(l)
        }
    }

    private func rewriteSelectedLines(_ transform: (String) -> String) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lineRange)
        let trailingNL = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNL { lines.removeLast() }
        let newBlock = lines.map(transform).joined(separator: "\n") + (trailingNL ? "\n" : "")
        replace(range: lineRange, with: newBlock,
                newSelection: NSRange(location: lineRange.location, length: (newBlock as NSString).length))
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

    /// 1-based source line → error message. Lines get a light-red background; hover / ⌘. shows the message.
    var errorInfo: [Int: String] = [:] {
        didSet { if errorInfo != oldValue { needsDisplay = true; if errorInfo[errorPopover.currentLine ?? -1] == nil { errorPopover.close() } } }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
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

    /// ⌘. → toggle the error popover for the cursor's line.
    private func toggleErrorPopoverAtCursor() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let line = ns.substring(to: loc).components(separatedBy: "\n").count
        guard let msg = errorInfo[line] else { NSSound.beep(); return }
        if errorPopover.isShown, errorPopover.currentLine == line { errorPopover.close() }
        else { errorPopover.show(message: msg, line: line, lineRect: lineRect(line, lm: lm, tc: tc), in: self) }
    }

    // MARK: - Scroll sync

    /// 1-based source line at the vertical center of the visible editor area.
    func lineAtVisibleCenter() -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let scroll = enclosingScrollView else { return nil }
        let o = textContainerOrigin
        let glyph = lm.glyphIndex(for: NSPoint(x: 4 - o.x, y: scroll.documentVisibleRect.midY - o.y), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let ns = string as NSString
        guard char <= ns.length else { return nil }
        return ns.substring(to: char).components(separatedBy: "\n").count
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

    static func apply(to lm: NSLayoutManager, string: String) {
        guard string.count < 300_000 else { return }
        let full = NSRange(string.startIndex..., in: string)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for rule in rules {
            rule.pattern.enumerateMatches(in: string, range: full) { m, _, _ in
                guard let m else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: rule.color, forCharacterRange: m.range)
            }
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        tv.usesRuler       = false
        tv.font            = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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

        scrollView.documentView = tv
        context.coordinator.textView = tv
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.editorScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? LaTeXTextView else { return }
        context.coordinator.texLabClient = texLabClient   // keep in sync
        context.coordinator.compiler = compiler
        if tv.string != text {
            tv.string = text
            if let lm = tv.layoutManager { Syntax.apply(to: lm, string: text) }
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
    private var scrollWork: DispatchWorkItem?

    init(_ parent: LaTeXEditorView) {
        self.parent = parent
        self.texLabClient = parent.texLabClient
        self.compiler = parent.compiler
    }

    // Scroll-sync (editor → PDF): center the PDF on the editor's center line, debounced.
    @MainActor @objc func editorScrolled() {
        guard compiler?.scrollSyncEnabled == true, compiler?.inSyncCooldown == false else { return }
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let line = self.textView?.lineAtVisibleCenter() else { return }
            Task { @MainActor in await self.compiler?.forwardSearch(line: line) }
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        parent.text = tv.string
        if let lm = tv.layoutManager { Syntax.apply(to: lm, string: tv.string) }
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
