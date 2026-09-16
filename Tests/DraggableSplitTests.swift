#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import iTex

@MainActor
final class DraggableSplitTests: XCTestCase {
    /// The toolbar Layout toggle must re-lay out the same pane views, not rebuild them (an
    /// editor rebuild drops undo/caret/scroll; a PDF view rebuild reloads the document).
    func testOrientationToggleKeepsPaneViews() throws {
        let panes = PaneRecorder()
        let host = NSHostingView(rootView: split(vertical: false, panes))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }

        XCTAssertTrue(spin(host) { panes.made == 2 })
        let first = try XCTUnwrap(panes.views["first"])
        XCTAssertTrue(spin(host) { first.frame.width > 0 && first.frame.width < first.frame.height },
                      "Side by side: the first pane is a column")

        host.rootView = split(vertical: true, panes)
        XCTAssertTrue(spin(host) { first.frame.width > first.frame.height },
                      "Stacked: the same first pane is now a row")
        XCTAssertEqual(panes.made, 2, "Toggling orientation must not rebuild either pane")
        XCTAssertTrue(panes.views["first"] === first)
    }

    private func split(vertical: Bool, _ panes: PaneRecorder) -> some View {
        DraggableSplit(vertical: vertical, fraction: .constant(0.5)) {
            RecordingPane(name: "first", panes: panes)
        } second: {
            RecordingPane(name: "second", panes: panes)
        }
    }

    private func spin(_ host: NSView, timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

private final class PaneRecorder {
    var made = 0
    var views: [String: NSView] = [:]
}

private struct RecordingPane: NSViewRepresentable {
    let name: String
    let panes: PaneRecorder

    func makeNSView(context: Context) -> NSView {
        panes.made += 1
        let view = NSView()
        panes.views[name] = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
