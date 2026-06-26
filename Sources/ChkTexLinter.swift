import Foundation
import Observation

@MainActor
@Observable
final class ChkTexLinter {
    struct Warning: Identifiable {
        let id = UUID()
        let line: Int
        let message: String
        let isError: Bool
    }

    var warnings: [Warning] = []
    private var task: Task<Void, Never>?

    func scheduleLint(fileURL: URL?) {
        guard let fileURL else { return }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.lint(fileURL: fileURL)
        }
    }

    func lint(fileURL: URL) async {
#if os(macOS)
        let output = await Task.detached(priority: .background) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.currentDirectoryURL = fileURL.deletingLastPathComponent()
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/Library/TeX/texbin:/usr/local/bin:/usr/bin:" + (env["PATH"] ?? "")
            process.environment = env
            // -q suppresses banner; -I suppresses first-run init messages
            process.arguments = ["chktex", "-q", "-I", fileURL.lastPathComponent]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe() // suppress to stderr

            try? process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value

        warnings = Self.parse(output: output)
#endif
    }

    // chktex default format: "Warning N in file line L: message"
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(Warning|Error) (\d+) in .+ line (\d+):\s*(.+)$"#,
        options: .anchorsMatchLines
    )

    private static func parse(output: String) -> [Warning] {
        let range = NSRange(output.startIndex..., in: output)
        return pattern.matches(in: output, range: range).compactMap { match in
            guard
                let typeRange = Range(match.range(at: 1), in: output),
                let lineRange = Range(match.range(at: 3), in: output),
                let msgRange  = Range(match.range(at: 4), in: output),
                let line = Int(output[lineRange])
            else { return nil }
            return Warning(
                line: line,
                message: String(output[msgRange]),
                isError: output[typeRange] == "Error"
            )
        }
    }
}
