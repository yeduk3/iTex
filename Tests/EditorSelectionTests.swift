import AppKit
import XCTest
@testable import iTex

@MainActor
final class EditorSelectionTests: XCTestCase {
    func testMultiLineTabPreservesPartialSelectionEdges() {
        let textView = LaTeXTextView()
        textView.string = "alpha\nbeta\ngamma"
        let selection = (textView.string as NSString).range(of: "pha\nbe")
        textView.setSelectedRange(selection)

        textView.insertTab(nil)

        XCTAssertEqual(textView.string, "\talpha\n\tbeta\ngamma")
        XCTAssertEqual(selectedText(in: textView), "pha\n\tbe")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 7))
    }

    func testTabDoesNotIncludeLineAtTrailingSelectionBoundary() {
        let textView = LaTeXTextView()
        textView.string = "alpha\nbeta"
        textView.setSelectedRange(NSRange(location: 0, length: 6))

        textView.insertTab(nil)

        XCTAssertEqual(textView.string, "\talpha\nbeta")
        XCTAssertEqual(selectedText(in: textView), "alpha\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 6))
    }

    func testMultiLineBacktabPreservesPartialSelectionEdges() {
        let textView = LaTeXTextView()
        textView.indentationWidth = 2
        textView.string = "\talpha\n  beta\ngamma"
        let selection = (textView.string as NSString).range(of: "pha\n  be")
        textView.setSelectedRange(selection)

        textView.insertBacktab(nil)

        XCTAssertEqual(textView.string, "alpha\nbeta\ngamma")
        XCTAssertEqual(selectedText(in: textView), "pha\nbe")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 6))
    }

    func testBacktabClampsCaretInsideRemovedIndentation() {
        let textView = LaTeXTextView()
        textView.indentationWidth = 2
        textView.string = "  alpha"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertBacktab(nil)

        XCTAssertEqual(textView.string, "alpha")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    private func selectedText(in textView: NSTextView) -> String {
        (textView.string as NSString).substring(with: textView.selectedRange())
    }
}
