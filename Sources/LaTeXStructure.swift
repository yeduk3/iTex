import Foundation

struct LaTeXEnvironmentPair: Equatable, Sendable {
    let name: String
    let beginCommandRange: NSRange
    let beginNameRange: NSRange
    let endCommandRange: NSRange
    let endNameRange: NSRange
    let fullRange: NSRange
    let startLine: Int
    let endLine: Int
    let depth: Int
}

struct LaTeXStructureIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unmatchedBegin
        case unexpectedEnd
        case mismatchedEnd
    }

    let kind: Kind
    let range: NSRange
    let line: Int
    let message: String
}

struct LaTeXStructureSnapshot: Equatable, Sendable {
    let pairs: [LaTeXEnvironmentPair]
    let issues: [LaTeXStructureIssue]

    static let empty = LaTeXStructureSnapshot(pairs: [], issues: [])

    /// Returns the enclosing environments from outermost to innermost.
    func pairs(containingUTF16Offset offset: Int) -> [LaTeXEnvironmentPair] {
        guard offset >= 0 else { return [] }
        return pairs
            .filter { NSLocationInRange(offset, $0.fullRange) }
            .sorted {
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                return $0.beginCommandRange.location < $1.beginCommandRange.location
            }
    }

    func innermostPair(containingUTF16Offset offset: Int) -> LaTeXEnvironmentPair? {
        pairs(containingUTF16Offset: offset).last
    }
}

enum LaTeXStructureAnalyzer {
    private struct OpenEnvironment {
        let name: String
        let commandRange: NSRange
        let nameRange: NSRange
        let line: Int
        let depth: Int
    }

    private struct EnvironmentCommand {
        enum Kind { case begin, end }

        let kind: Kind
        let name: String
        let commandRange: NSRange
        let nameRange: NSRange
    }

    private static let opaqueEnvironmentNames: Set<String> = [
        "verbatim", "verbatimtab", "bverbatim", "lverbatim", "saveverbatim",
        "lstlisting", "minted"
    ]

    static func analyze(_ source: String) -> LaTeXStructureSnapshot {
        let units = Array(source.utf16)
        guard !units.isEmpty else { return .empty }

        var stack: [OpenEnvironment] = []
        var pairs: [LaTeXEnvironmentPair] = []
        var issues: [LaTeXStructureIssue] = []
        var opaqueEnvironment: String?
        var offset = 0
        var line = 1

        while offset < units.count {
            let character = units[offset]

            if let opaqueName = opaqueEnvironment {
                guard character == asciiBackslash else {
                    advanceOne(in: units, offset: &offset, line: &line)
                    continue
                }

                let controlEnd = controlSequenceEnd(in: units, from: offset)
                if controlWord(in: units, from: offset, to: controlEnd) == "end",
                   let command = environmentCommand(in: units, from: offset, controlEnd: controlEnd),
                   command.kind == .end,
                   command.name == opaqueName {
                    close(command, atLine: line, stack: &stack, pairs: &pairs, issues: &issues)
                    opaqueEnvironment = nil
                    advance(in: units, offset: &offset, to: NSMaxRange(command.commandRange), line: &line)
                } else {
                    advance(in: units, offset: &offset, to: controlEnd, line: &line)
                }
                continue
            }

            if character == asciiPercent {
                // Escaped percent signs were already consumed as a two-character control symbol.
                while offset < units.count && units[offset] != asciiLineFeed && units[offset] != asciiCarriageReturn {
                    offset += 1
                }
                continue
            }

            guard character == asciiBackslash else {
                advanceOne(in: units, offset: &offset, line: &line)
                continue
            }

            let controlEnd = controlSequenceEnd(in: units, from: offset)
            let word = controlWord(in: units, from: offset, to: controlEnd)

            if word == "verb" {
                var bodyStart = controlEnd
                if bodyStart < units.count && units[bodyStart] == asciiAsterisk { bodyStart += 1 }
                let end = verbEnd(in: units, delimiterOffset: bodyStart)
                advance(in: units, offset: &offset, to: end, line: &line)
                continue
            }

            if (word == "begin" || word == "end"),
               let command = environmentCommand(in: units, from: offset, controlEnd: controlEnd) {
                switch command.kind {
                case .begin:
                    let opened = OpenEnvironment(
                        name: command.name,
                        commandRange: command.commandRange,
                        nameRange: command.nameRange,
                        line: line,
                        depth: stack.count
                    )
                    stack.append(opened)
                    if isOpaqueEnvironment(command.name) { opaqueEnvironment = command.name }
                case .end:
                    close(command, atLine: line, stack: &stack, pairs: &pairs, issues: &issues)
                }
                advance(in: units, offset: &offset, to: NSMaxRange(command.commandRange), line: &line)
            } else {
                // Consume the complete control sequence. This is important for `\\begin`,
                // whose second backslash must not be interpreted as a new command.
                advance(in: units, offset: &offset, to: controlEnd, line: &line)
            }
        }

        for opened in stack {
            issues.append(unmatchedIssue(for: opened))
        }

        pairs.sort { $0.beginCommandRange.location < $1.beginCommandRange.location }
        issues.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length < $1.range.length
        }
        return LaTeXStructureSnapshot(pairs: pairs, issues: issues)
    }

    private static func close(
        _ command: EnvironmentCommand,
        atLine line: Int,
        stack: inout [OpenEnvironment],
        pairs: inout [LaTeXEnvironmentPair],
        issues: inout [LaTeXStructureIssue]
    ) {
        guard let current = stack.last else {
            issues.append(LaTeXStructureIssue(
                kind: .unexpectedEnd,
                range: command.commandRange,
                line: line,
                message: "Unexpected \\end{\(command.name)} with no open environment."
            ))
            return
        }

        if current.name == command.name {
            stack.removeLast()
            pairs.append(pair(current, command, endLine: line))
            return
        }

        issues.append(LaTeXStructureIssue(
            kind: .mismatchedEnd,
            range: command.commandRange,
            line: line,
            message: "Expected \\end{\(current.name)}, but found \\end{\(command.name)}."
        ))

        // If this end belongs to an ancestor, close that ancestor and report only the
        // intervening opens. Otherwise leave the stack intact so later correct ends
        // can still recover without a cascade of false errors.
        guard let matchingIndex = stack.lastIndex(where: { $0.name == command.name }) else { return }
        while stack.count - 1 > matchingIndex {
            issues.append(unmatchedIssue(for: stack.removeLast()))
        }
        let matching = stack.removeLast()
        pairs.append(pair(matching, command, endLine: line))
    }

    private static func pair(
        _ opened: OpenEnvironment,
        _ closed: EnvironmentCommand,
        endLine: Int
    ) -> LaTeXEnvironmentPair {
        LaTeXEnvironmentPair(
            name: opened.name,
            beginCommandRange: opened.commandRange,
            beginNameRange: opened.nameRange,
            endCommandRange: closed.commandRange,
            endNameRange: closed.nameRange,
            fullRange: NSRange(
                location: opened.commandRange.location,
                length: NSMaxRange(closed.commandRange) - opened.commandRange.location
            ),
            startLine: opened.line,
            endLine: endLine,
            depth: opened.depth
        )
    }

    private static func unmatchedIssue(for opened: OpenEnvironment) -> LaTeXStructureIssue {
        LaTeXStructureIssue(
            kind: .unmatchedBegin,
            range: opened.commandRange,
            line: opened.line,
            message: "No matching \\end{\(opened.name)} for \\begin{\(opened.name)}."
        )
    }

    private static func environmentCommand(
        in units: [UInt16],
        from start: Int,
        controlEnd: Int
    ) -> EnvironmentCommand? {
        let word = controlWord(in: units, from: start, to: controlEnd)
        let kind: EnvironmentCommand.Kind
        if word == "begin" { kind = .begin }
        else if word == "end" { kind = .end }
        else { return nil }

        var cursor = controlEnd
        while cursor < units.count && isASCIIWhitespace(units[cursor]) { cursor += 1 }
        guard cursor < units.count, units[cursor] == asciiOpenBrace else { return nil }
        cursor += 1

        let rawNameStart = cursor
        while cursor < units.count {
            let character = units[cursor]
            if character == asciiCloseBrace { break }
            if character == asciiOpenBrace || character == asciiLineFeed || character == asciiCarriageReturn { return nil }
            cursor += 1
        }
        guard cursor < units.count, units[cursor] == asciiCloseBrace else { return nil }

        var nameStart = rawNameStart
        var nameEnd = cursor
        while nameStart < nameEnd && isASCIIWhitespace(units[nameStart]) { nameStart += 1 }
        while nameEnd > nameStart && isASCIIWhitespace(units[nameEnd - 1]) { nameEnd -= 1 }
        guard nameStart < nameEnd else { return nil }

        let name = String(decoding: units[nameStart..<nameEnd], as: UTF16.self)
        return EnvironmentCommand(
            kind: kind,
            name: name,
            commandRange: NSRange(location: start, length: cursor + 1 - start),
            nameRange: NSRange(location: nameStart, length: nameEnd - nameStart)
        )
    }

    private static func controlSequenceEnd(in units: [UInt16], from start: Int) -> Int {
        guard start + 1 < units.count else { return units.count }
        var cursor = start + 1
        if isASCIILetter(units[cursor]) {
            while cursor < units.count && isASCIILetter(units[cursor]) { cursor += 1 }
            return cursor
        }
        return cursor + 1
    }

    private static func controlWord(in units: [UInt16], from start: Int, to end: Int) -> String? {
        guard start + 1 < end, isASCIILetter(units[start + 1]) else { return nil }
        return String(decoding: units[(start + 1)..<end], as: UTF16.self)
    }

    private static func verbEnd(in units: [UInt16], delimiterOffset: Int) -> Int {
        guard delimiterOffset < units.count else { return units.count }
        let delimiter = units[delimiterOffset]
        guard delimiter != asciiLineFeed && delimiter != asciiCarriageReturn else { return delimiterOffset }
        var cursor = delimiterOffset + 1
        while cursor < units.count {
            if units[cursor] == delimiter { return cursor + 1 }
            if units[cursor] == asciiLineFeed || units[cursor] == asciiCarriageReturn { return cursor }
            cursor += 1
        }
        return cursor
    }

    private static func isOpaqueEnvironment(_ name: String) -> Bool {
        var normalized = name.lowercased()
        if normalized.hasSuffix("*") { normalized.removeLast() }
        return opaqueEnvironmentNames.contains(normalized)
    }

    private static func advanceOne(in units: [UInt16], offset: inout Int, line: inout Int) {
        if units[offset] == asciiCarriageReturn {
            line += 1
            offset += 1
            if offset < units.count && units[offset] == asciiLineFeed { offset += 1 }
        } else {
            if units[offset] == asciiLineFeed { line += 1 }
            offset += 1
        }
    }

    private static func advance(in units: [UInt16], offset: inout Int, to end: Int, line: inout Int) {
        let target = min(end, units.count)
        while offset < target { advanceOne(in: units, offset: &offset, line: &line) }
    }

    private static func isASCIILetter(_ character: UInt16) -> Bool {
        (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
    }

    private static func isASCIIWhitespace(_ character: UInt16) -> Bool {
        character == 32 || character == 9 || character == asciiLineFeed || character == asciiCarriageReturn
    }

    private static let asciiLineFeed: UInt16 = 10
    private static let asciiCarriageReturn: UInt16 = 13
    private static let asciiPercent: UInt16 = 37
    private static let asciiAsterisk: UInt16 = 42
    private static let asciiBackslash: UInt16 = 92
    private static let asciiOpenBrace: UInt16 = 123
    private static let asciiCloseBrace: UInt16 = 125
}
