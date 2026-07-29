import Foundation
import XCTest
@testable import iTex

final class CompileCancellationTests: XCTestCase {
    func testCancellingSubprocessStopsTermIgnoringProcessTree() async throws {
        let cwd = FileManager.default.temporaryDirectory
        let started = Date()
        let task = Task {
            await Subprocess.run(
                ["-c", "trap '' TERM; (trap '' TERM; sleep 30) & wait"],
                cwd: cwd,
                launch: "/bin/sh"
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = await task.value

        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 4,
                          "Cancellation should hard-stop a TeX-like child tree instead of waiting for it.")
    }
}
