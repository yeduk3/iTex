#if os(macOS)
import Foundation

/// One tab stop inside an inserted snippet. `range` is relative to the snippet's plain text at
/// parse time; the editor re-bases it into document coordinates when the session starts.
struct SnippetStop {
    let index: Int
    var range: NSRange
    let placeholder: String
}

/// Parsed LSP snippet: plain insert text plus ordered tab stops. `$0` becomes `finalCaret`.
struct Snippet {
    let text: String
    var stops: [SnippetStop]
    var finalCaret: Int
    var hasStops: Bool { !stops.isEmpty }

    /// Parse `$1`, `${1:placeholder}`, `${1|a,b|}` (first choice), `$0`, `\$` / `\\` / `\}` escapes.
    /// Unknown or malformed constructs degrade to their literal text; never throws.
    static func parse(_ source: String) -> Snippet {
        var out = "", u16 = 0
        var stops: [SnippetStop] = []
        var finalCaret: Int? = nil
        let chars = Array(source)
        var i = 0
        func emit(_ s: String) { out += s; u16 += (s as NSString).length }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "$\\}".contains(chars[i + 1]) {
                emit(String(chars[i + 1])); i += 2; continue
            }
            if c == "$", let (idx, placeholder, next) = parseStop(chars, i) {
                let loc = u16
                emit(placeholder)
                if idx == 0 { finalCaret = loc }
                else { stops.append(SnippetStop(index: idx,
                                                range: NSRange(location: loc, length: (placeholder as NSString).length),
                                                placeholder: placeholder)) }
                i = next; continue
            }
            emit(String(c)); i += 1
        }
        stops.sort { $0.index < $1.index }
        return Snippet(text: out, stops: stops, finalCaret: finalCaret ?? u16)
    }

    /// Parse a single stop starting at `chars[i] == "$"`. Returns (index, placeholder, indexAfterStop).
    private static func parseStop(_ chars: [Character], _ i: Int) -> (Int, String, Int)? {
        var j = i + 1
        guard j < chars.count else { return nil }
        if chars[j] == "{" {
            j += 1
            var num = ""
            while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
            guard !num.isEmpty, let idx = Int(num), j < chars.count else { return nil }
            switch chars[j] {
            case "}":
                return (idx, "", j + 1)
            case ":":
                j += 1
                var depth = 1, text = ""
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count { text.append(chars[j + 1]); j += 2; continue }
                    if chars[j] == "{" { depth += 1 }
                    else if chars[j] == "}" { depth -= 1; if depth == 0 { return (idx, text, j + 1) } }
                    text.append(chars[j]); j += 1
                }
                return nil
            case "|":
                j += 1
                var text = ""
                while j < chars.count, chars[j] != "|" { text.append(chars[j]); j += 1 }
                guard j + 1 < chars.count, chars[j] == "|", chars[j + 1] == "}" else { return nil }
                let first = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                return (idx, first, j + 2)
            default:
                return nil
            }
        }
        if chars[j].isNumber {
            var num = ""
            while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
            return (Int(num) ?? 0, "", j)
        }
        return nil
    }

    /// Static-list fallback: each empty `{}` / `[]` group becomes an ordered empty tab stop.
    /// nil when the text holds no empty group.
    static func fromEmptyGroups(_ text: String) -> Snippet? {
        let ns = text as NSString
        var stops: [SnippetStop] = []
        var idx = 1, i = 0
        while i + 1 < ns.length {
            let c = ns.character(at: i), n = ns.character(at: i + 1)
            if (c == 0x7B && n == 0x7D) || (c == 0x5B && n == 0x5D) {   // {} or []
                stops.append(SnippetStop(index: idx, range: NSRange(location: i + 1, length: 0), placeholder: ""))
                idx += 1; i += 2
            } else { i += 1 }
        }
        guard !stops.isEmpty else { return nil }
        return Snippet(text: text, stops: stops, finalCaret: ns.length)
    }
}
#endif
