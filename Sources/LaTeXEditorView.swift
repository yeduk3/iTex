import SwiftUI

#if os(macOS)
import AppKit

// MARK: - NSTextView subclass

final class LaTeXTextView: NSTextView {
    // Auto-trigger: if inside \word, fetch texlab completions then show popup
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let s = string as? String,
              s.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
        else { return }
        triggerCompletionIfInCommand()
    }

    private func triggerCompletionIfInCommand() {
        let loc  = selectedRange().location
        let text = self.string
        guard loc > 0 else { return }
        let start  = text.index(text.startIndex, offsetBy: max(0, loc - 40))
        let end    = text.index(text.startIndex, offsetBy: loc)
        let recent = String(text[start..<end])
        guard let lastBS = recent.lastIndex(of: "\\") else { return }
        let afterBS = recent[recent.index(after: lastBS)...]
        guard afterBS.allSatisfy(\.isLetter) else { return }

        guard let coord = delegate as? Coordinator,
              let client = coord.texLabClient else {
            complete(nil)   // static fallback
            return
        }

        // Fetch from texlab async, then show popup
        let (line, col) = lspPosition(in: text, at: loc)
        Task { @MainActor in
            _ = await client.requestCompletions(line: line, character: col)
            self.complete(nil)
        }
    }

    // Extend replacement range to include the preceding '\'
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal: Bool) {
        var range = charRange
        if range.location > 0, (self.string as NSString).character(at: range.location - 1) == 0x5C {
            range.location -= 1
            range.length   += 1
        }
        super.insertCompletion(word, forPartialWordRange: range, movement: movement, isFinal: isFinal)
    }

    private func lspPosition(in text: String, at loc: Int) -> (Int, Int) {
        let prefix = String(text.prefix(loc))
        let lines  = prefix.components(separatedBy: "\n")
        return (lines.count - 1, lines.last?.count ?? 0)
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
        // SyncTeX inverse search: select the requested source line once per request.
        if let req = compiler?.selectLineRequest, req.token != context.coordinator.lastSelectToken {
            context.coordinator.lastSelectToken = req.token
            if let range = LaTeXEditorView.range(ofLine: req.line, in: tv.string) {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
                tv.window?.makeFirstResponder(tv)
            }
        }
    }
}

// MARK: - Coordinator

final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: LaTeXEditorView
    var texLabClient: TexLabClient?
    var compiler: LaTeXCompiler?
    var lastSelectToken = -1

    init(_ parent: LaTeXEditorView) {
        self.parent = parent
        self.texLabClient = parent.texLabClient
        self.compiler = parent.compiler
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        parent.text = tv.string
        if let lm = tv.layoutManager { Syntax.apply(to: lm, string: tv.string) }
    }

    // Track cursor line for SyncTeX forward search.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, let compiler else { return }
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        compiler.cursorLine = ns.substring(to: loc).components(separatedBy: "\n").count
    }

    func textView(_ textView: NSTextView,
                  completions words: [String],
                  forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let ns = textView.string as NSString
        let prefix: String = charRange.location > 0 && ns.character(at: charRange.location - 1) == 0x5C
            ? "\\" + ns.substring(with: charRange)
            : ns.substring(with: charRange)

        // Use texlab completions when available; static list as fallback
        if let client = texLabClient, !client.latestCompletions.isEmpty {
            let results = client.latestCompletions
                .map(\.label)
                .filter { $0.hasPrefix(prefix) }
                .sorted()
            if !results.isEmpty {
                index?.pointee = 0
                return results
            }
        }
        let results = LaTeXCommands.completions(for: prefix)
        index?.pointee = results.isEmpty ? -1 : 0
        return results
    }
}

#else
// MARK: - iOS (plain UITextView, no texlab)

import UIKit

struct LaTeXEditorView: UIViewRepresentable {
    @Binding var text: String
    var texLabClient: TexLabClient? = nil   // unused on iOS
    var compiler: LaTeXCompiler? = nil      // unused on iOS (no SyncTeX subprocess)

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
