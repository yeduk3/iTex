import Foundation
import XCTest
@testable import iTex

final class LaTeXStructureTests: XCTestCase {
    func testNestedPairsCarryDepthAndExactNameRanges() {
        let source = #"""
        \begin{document}
        \begin{figure}
        \begin{figure*}
        body
        \end{figure*}
        \end{figure}
        \end{document}
        """#

        let snapshot = LaTeXStructureAnalyzer.analyze(source)

        XCTAssertEqual(snapshot.issues, [])
        XCTAssertEqual(snapshot.pairs.map(\.name), ["document", "figure", "figure*"])
        XCTAssertEqual(snapshot.pairs.map(\.depth), [0, 1, 2])
        let ns = source as NSString
        for pair in snapshot.pairs {
            XCTAssertEqual(ns.substring(with: pair.beginNameRange), pair.name)
            XCTAssertEqual(ns.substring(with: pair.endNameRange), pair.name)
        }

        let bodyOffset = ns.range(of: "body").location
        XCTAssertEqual(snapshot.pairs(containingUTF16Offset: bodyOffset).map(\.name),
                       ["document", "figure", "figure*"])
        XCTAssertEqual(snapshot.innermostPair(containingUTF16Offset: bodyOffset)?.name, "figure*")
    }

    func testCommentsVerbAndOpaqueBodiesDoNotCreateFalsePairs() {
        let source = #"""
        % \begin{commented}
        \verb|\begin{inlineFake}| 
        \begin{minted}{swift}
        \begin{bodyFake}
        \end{notMinted}
        \end{minted}
        \begin{real}
        \end{real}
        """#

        let snapshot = LaTeXStructureAnalyzer.analyze(source)

        XCTAssertEqual(snapshot.issues, [])
        XCTAssertEqual(snapshot.pairs.map(\.name), ["minted", "real"])
    }

    func testEscapedPercentDoesNotTurnRestOfLineIntoComment() {
        let source = #"\% literal percent \begin{real}x\end{real}"#

        let snapshot = LaTeXStructureAnalyzer.analyze(source)

        XCTAssertEqual(snapshot.issues, [])
        XCTAssertEqual(snapshot.pairs.map(\.name), ["real"])
    }

    func testAncestorMismatchRecoversWithoutLosingTheOuterPair() {
        let source = #"""
        \begin{outer}
        \begin{inner}
        \end{outer}
        """#

        let snapshot = LaTeXStructureAnalyzer.analyze(source)

        XCTAssertEqual(snapshot.pairs.map(\.name), ["outer"])
        XCTAssertEqual(snapshot.issues.map(\.kind), [.unmatchedBegin, .mismatchedEnd])
        XCTAssertEqual(snapshot.issues.map(\.line), [2, 3])
    }

    func testUnexpectedEndAndOpenEnvironmentAtEOFProduceIssues() {
        let source = #"""
        \end{orphan}
        \begin{open}
        """#

        let snapshot = LaTeXStructureAnalyzer.analyze(source)

        XCTAssertTrue(snapshot.pairs.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.kind), [.unexpectedEnd, .unmatchedBegin])
        XCTAssertEqual(snapshot.issues.map(\.line), [1, 2])
    }

    func testRangesUseUTF16Offsets() {
        let source = "🧪 " + #"\begin{box}x\end{box}"#
        let snapshot = LaTeXStructureAnalyzer.analyze(source)
        let pair = try! XCTUnwrap(snapshot.pairs.first)
        let ns = source as NSString

        XCTAssertEqual(pair.beginCommandRange.location, 3)
        XCTAssertEqual(ns.substring(with: pair.beginNameRange), "box")
        XCTAssertEqual(ns.substring(with: pair.endNameRange), "box")
    }
}
