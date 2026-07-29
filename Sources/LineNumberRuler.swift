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
    /// A narrow trailing lane for structural scope rails and issue markers. Keeping it
    /// separate from the number column preserves the existing number alignment as the
    /// document grows from two to three (or more) digits.
    private let annotationLaneWidth: CGFloat = 18

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // NSRulerView normally reserves a 15pt marker strip and draws its own baseline. A line
        // number gutter has neither markers nor an accessory view; leaving that strip enabled
        // exposes the baseline above/outside the editor when the scroll view is tiled.
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        accessoryView = nil
        markers = []
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

    /// Own the complete ruler drawing so NSRulerView does not add its default baseline or marker
    /// strip. The trailing separator below is the only rule drawn by this gutter.
    override func draw(_ dirtyRect: NSRect) {
        let clipped = dirtyRect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipped).addClip()
        drawHashMarksAndLabels(in: clipped)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawMarkers(in rect: NSRect) {}

    private var digitFont: NSFont {
        let base = textView?.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return .monospacedDigitSystemFont(ofSize: (base.pointSize * 0.85).rounded(), weight: .regular)
    }

    private func updateTotalLines() {
        guard let tv = textView else { return }
        totalLines = max(1, (tv.string as NSString).components(separatedBy: "\n").count)
        let digits = max(2, String(totalLines).count)
        let w = ("0" as NSString).size(withAttributes: [.font: digitFont]).width
        let thickness = ceil(CGFloat(digits) * w) + padding * 2 + annotationLaneWidth
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
        var visibleLineFragments: [Int: NSRect] = [:]

        let draw: (Int, NSRect) -> Void = { number, fragRect in
            let color: NSColor = number == caretLine ? .labelColor : .tertiaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            let x = self.ruleThickness - self.annotationLaneWidth - size.width - self.padding
            let y = relativeY + fragRect.minY + insetY + (fragRect.height - size.height) / 2
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            visibleLineFragments[number] = fragRect
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

        if let editor = tv as? LaTeXTextView {
            drawStructureAnnotations(for: editor, layoutManager: lm, textContainer: tc,
                                     visibleRect: visible, relativeY: relativeY,
                                     visibleLineFragments: visibleLineFragments)
        }

        // A one-device-pixel semantic separator, kept inside the ruler's trailing edge.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let separatorWidth = 1 / max(1, scale)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - separatorWidth, y: bounds.minY,
               width: separatorWidth, height: bounds.height).fill()
    }

    private func drawStructureAnnotations(
        for editor: LaTeXTextView,
        layoutManager lm: NSLayoutManager,
        textContainer tc: NSTextContainer,
        visibleRect: NSRect,
        relativeY: CGFloat,
        visibleLineFragments: [Int: NSRect]
    ) {
        let laneMinX = bounds.maxX - annotationLaneWidth
        let railAreaWidth: CGFloat = 12
        let railSpacing: CGFloat = railAreaWidth / 6
        let capLength: CGFloat = 2.5
        let insetY = editor.textContainerOrigin.y
        let visibleMinY = max(bounds.minY, relativeY + visibleRect.minY)
        let visibleMaxY = min(bounds.maxY, relativeY + visibleRect.maxY)
        guard visibleMaxY >= visibleMinY else { return }
        let visibleGlyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let visibleCharacterRange = lm.characterRange(forGlyphRange: visibleGlyphRange,
                                                       actualGlyphRange: nil)

        // Prefer the innermost six ancestors in unusually deep documents. The pair's
        // actual depth still selects its color; the local slot only prevents overlap.
        let activePairs = Array(editor.activeEnvironmentPairs.suffix(6))
        for (slot, pair) in activePairs.enumerated() {
            let visibleEnd = NSMaxRange(visibleCharacterRange)
            let pairEnd = NSMaxRange(pair.fullRange)
            guard pairEnd >= visibleCharacterRange.location,
                  pair.fullRange.location <= visibleEnd
            else { continue }
            guard let begin = endpoint(forCharacterAt: pair.beginNameRange.location,
                                       in: editor, layoutManager: lm,
                                       visibleCharacterRange: visibleCharacterRange,
                                       visibleMinY: visibleMinY, visibleMaxY: visibleMaxY,
                                       relativeY: relativeY),
                  let end = endpoint(forCharacterAt: pair.endNameRange.location,
                                     in: editor, layoutManager: lm,
                                     visibleCharacterRange: visibleCharacterRange,
                                     visibleMinY: visibleMinY, visibleMaxY: visibleMaxY,
                                     relativeY: relativeY)
            else { continue }

            let railX = laneMinX + 0.75 + CGFloat(slot) * railSpacing
            let startY = max(min(begin.y, end.y), visibleMinY)
            let finishY = min(max(begin.y, end.y), visibleMaxY)
            guard finishY >= startY else { continue }

            let color = LaTeXTextView.pairColor(forDepth: pair.depth).withAlphaComponent(0.72)
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: railX, y: startY))
            path.line(to: NSPoint(x: railX, y: finishY))

            // Caps only appear when the actual endpoint is visible. Spans crossing the
            // viewport edge remain a continuous rail rather than looking artificially closed.
            if begin.isVisible {
                path.move(to: NSPoint(x: railX, y: begin.y))
                path.line(to: NSPoint(x: railX + capLength, y: begin.y))
            }
            if end.isVisible {
                path.move(to: NSPoint(x: railX, y: end.y))
                path.line(to: NSPoint(x: railX + capLength, y: end.y))
            }
            path.stroke()
        }

        // Line fragments were already discovered while numbering the visible glyph range,
        // so issue drawing does not scan or lay out the rest of the document.
        let issueLines = Set(editor.structureSnapshot.issues.map(\.line))
        NSColor.systemRed.setFill()
        for line in issueLines {
            guard let frag = visibleLineFragments[line] else { continue }
            let centerY = relativeY + insetY + frag.midY
            let marker = NSRect(x: bounds.maxX - 5.5, y: centerY - 2,
                                width: 4, height: 4)
            NSBezierPath(ovalIn: marker).fill()
        }
    }

    /// Returns a token's line-fragment center in ruler coordinates. Offscreen endpoints clamp
    /// directly to the viewport edge without asking NSLayoutManager to lay out distant text.
    private func endpoint(
        forCharacterAt location: Int,
        in editor: LaTeXTextView,
        layoutManager lm: NSLayoutManager,
        visibleCharacterRange: NSRange,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat,
        relativeY: CGFloat
    ) -> (y: CGFloat, isVisible: Bool)? {
        let ns = editor.string as NSString
        guard ns.length > 0 else { return nil }
        let characterIndex = min(max(0, location), ns.length - 1)
        if characterIndex < visibleCharacterRange.location {
            return (visibleMinY, false)
        }
        if characterIndex >= NSMaxRange(visibleCharacterRange) {
            return (visibleMaxY, false)
        }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: characterIndex, length: 1),
                                       actualCharacterRange: nil)
        guard glyphRange.location < lm.numberOfGlyphs else { return nil }
        let fragment = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let y = relativeY + editor.textContainerOrigin.y + fragment.midY
        return (min(max(y, visibleMinY), visibleMaxY), y >= visibleMinY && y <= visibleMaxY)
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
