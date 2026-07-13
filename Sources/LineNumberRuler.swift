#if os(macOS)
import AppKit

/// Line-number gutter drawn in the scroll view's vertical ruler. Numbers only the visible
/// glyph range (no per-frame document scan) and only the first fragment of each hard line,
/// so soft-wrapped continuations stay blank. Colors, digit font size and thickness follow
/// the editor's font; all colors are semantic (auto light/dark).
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var totalLines = 1
    private var observers: [NSObjectProtocol] = []
    private let padding: CGFloat = 5

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateTotalLines()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSText.didChangeNotification, object: textView,
                                        queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(nc.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView,
                                        queue: .main) { [weak self] _ in self?.needsDisplay = true })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                        queue: .main) { [weak self] _ in self?.needsDisplay = true })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Recompute the line count / thickness and redraw (text or font size changed).
    func refresh() { updateTotalLines(); needsDisplay = true }

    private var digitFont: NSFont {
        let base = textView?.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return .monospacedDigitSystemFont(ofSize: (base.pointSize * 0.85).rounded(), weight: .regular)
    }

    private func updateTotalLines() {
        guard let tv = textView else { return }
        totalLines = max(1, (tv.string as NSString).components(separatedBy: "\n").count)
        let digits = max(2, String(totalLines).count)
        let w = ("0" as NSString).size(withAttributes: [.font: digitFont]).width
        let thickness = ceil(CGFloat(digits) * w) + padding * 2
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString

        tv.backgroundColor.setFill()
        bounds.fill()

        let font = digitFont
        let visible = tv.visibleRect
        let relativeY = convert(NSPoint.zero, from: tv).y
        let insetY = tv.textContainerOrigin.y

        let caretLoc = min(tv.selectedRange().location, ns.length)
        let caretLine = ns.substring(to: caretLoc).components(separatedBy: "\n").count

        let draw: (Int, NSRect) -> Void = { number, fragRect in
            let color: NSColor = number == caretLine ? .labelColor : .tertiaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - self.padding
            let y = relativeY + fragRect.minY + insetY + (fragRect.height - size.height) / 2
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        if glyphRange.length > 0 {
            let firstChar = lm.characterIndexForGlyph(at: glyphRange.location)
            var lineNumber = ns.substring(to: firstChar).components(separatedBy: "\n").count
            var scannedFrom = firstChar
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
                let charIndex = lm.characterIndexForGlyph(at: fragGlyphRange.location)
                let hardStart = charIndex == 0 || ns.character(at: charIndex - 1) == 0x0A
                guard hardStart else { return }             // soft-wrap continuation → no number
                if charIndex > scannedFrom {
                    lineNumber += self.newlineCount(ns, NSRange(location: scannedFrom, length: charIndex - scannedFrom))
                    scannedFrom = charIndex
                }
                draw(lineNumber, fragRect)
            }
        }

        // Trailing empty line (doc ends with newline) or empty document: numbered via the extra fragment.
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0, extra.maxY >= visible.minY, extra.minY <= visible.maxY {
                draw(totalLines, extra)
            }
        }
    }

    private func newlineCount(_ ns: NSString, _ range: NSRange) -> Int {
        var count = 0, i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: end - i))
            if r.location == NSNotFound { break }
            count += 1; i = r.location + 1
        }
        return count
    }
}
#endif
