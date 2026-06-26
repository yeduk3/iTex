import Foundation
import CoreGraphics

// SyncTeX forward/inverse search (docs/03 §3.10, docs/04 §4.3).
// ponytail: shell out to the installed `synctex` CLI rather than vendoring synctex_parser.c.
// The CLI already returns 72-dpi (PDF big-point) coordinates with magnification/offsets applied,
// which sidesteps the small-points×Unit / `/65536` pitfall the parser header warns about.

struct SyncTeXForwardResult {
    let page: Int          // 1-based
    let rect: CGRect       // PDFKit page coordinates (origin bottom-left), already Y-flipped
}

struct SyncTeXInverseResult {
    let file: String
    let line: Int          // 1-based
    let column: Int
}

#if os(macOS)

enum SyncTeXService {
    /// Forward search: editor (line,column) → highlight rects in the PDF.
    /// `pageHeights[page]` (1-based) must give each page's height in PDF points for the Y-flip.
    static func forward(line: Int, column: Int = 0, texFile: URL, pdf: URL,
                        pageHeight: @escaping (Int) -> CGFloat) async -> [SyncTeXForwardResult] {
        let r = await Subprocess.run(
            ["synctex", "view", "-i", "\(line):\(column):\(texFile.path)", "-o", pdf.path],
            cwd: pdf.deletingLastPathComponent())
        guard r.status == 0 else { return [] }
        return parseForward(r.output, pageHeight: pageHeight)
    }

    /// Inverse search: a click in the PDF → source (file,line).
    /// `point` is in PDFKit page coordinates (origin bottom-left); `pageHeight` flips it for SyncTeX.
    static func inverse(page: Int, point: CGPoint, pageHeight: CGFloat, pdf: URL) async -> SyncTeXInverseResult? {
        let yTop = pageHeight - point.y                 // SyncTeX origin is top-left (y down)
        let r = await Subprocess.run(
            ["synctex", "edit", "-o", "\(page):\(point.x):\(yTop):\(pdf.path)"],
            cwd: pdf.deletingLastPathComponent())
        guard r.status == 0 else { return nil }
        return parseInverse(r.output)
    }

    // MARK: - Parsing

    // `synctex view` emits repeated records: Page: / x: / y: / h: / v: / W: / H:
    // h,v = box upper-left (top-left origin, big points); W,H = width/height.
    static func parseForward(_ out: String, pageHeight: @escaping (Int) -> CGFloat) -> [SyncTeXForwardResult] {
        var results: [SyncTeXForwardResult] = []
        var page: Int?, h: CGFloat?, v: CGFloat?, w: CGFloat?, hh: CGFloat?

        func flush() {
            if let page, let h, let v, let w, let hh, w > 0, hh > 0 {
                let y = pageHeight(page) - v - hh         // flip to PDFKit (origin bottom-left)
                results.append(.init(page: page, rect: CGRect(x: h, y: y, width: w, height: hh)))
            }
            h = nil; v = nil; w = nil; hh = nil
        }

        for raw in out.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let val = field(l, "Page:") { flush(); page = Int(val) }
            else if let val = field(l, "h:") { h = num(val) }
            else if let val = field(l, "v:") { v = num(val) }
            else if let val = field(l, "W:") { w = num(val) }
            else if let val = field(l, "H:") { hh = num(val) }
        }
        flush()
        return results
    }

    // `synctex edit` emits: Output: / Input:<file> / Line:<n> / Column:<m>
    static func parseInverse(_ out: String) -> SyncTeXInverseResult? {
        var file: String?, line: Int?, col = 0
        for raw in out.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let v = field(l, "Input:") { file = v }
            else if let v = field(l, "Line:") { line = Int(v) }
            else if let v = field(l, "Column:") { col = Int(v) ?? 0 }
        }
        guard let file, let line else { return nil }
        return .init(file: file, line: line, column: col)
    }

    private static func field(_ line: String, _ key: String) -> String? {
        line.hasPrefix(key) ? String(line.dropFirst(key.count)) : nil
    }
    private static func num(_ s: String) -> CGFloat? { Double(s).map { CGFloat($0) } }
}

#endif
