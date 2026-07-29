#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class TexLabClient {
    private(set) var latestCompletions: [(label: String, insertText: String)] = []
    private(set) var isReady = false
    var onDiagnostics: (([Diagnostic]) -> Void)?

    private var process: Process?
    private var writer: FileHandle?
    private var buffer = Data()
    private var nextID = 2          // 1 is used for initialize
    private var currentURI = ""
    private var documentVersion = 1
    private var initialized = false
    private var pendingCompletions: [Int: CheckedContinuation<[(label: String, insertText: String)], Never>] = [:]

    // MARK: - Public API

    func start(workspaceURL: URL) {
        guard let exec = findTexlab() else { return }

        let proc = Process()
        proc.executableURL = exec
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput  = inPipe
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()

        do { try proc.run() } catch { return }
        process = proc
        writer  = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.buffer.append(d)
                self?.flush()
            }
        }

        send(request: 1, method: "initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": workspaceURL.absoluteString,
            "capabilities": [
                "textDocument": [
                    "completion": [
                        "completionItem": ["snippetSupport": true],
                        "completionItemKind": ["valueSet": Array(1...25)],
                    ]
                ]
            ],
            "workspaceFolders": [["uri": workspaceURL.absoluteString, "name": workspaceURL.lastPathComponent]]
        ] as [String: Any])
    }

    func openDocument(url: URL, text: String) {
        guard isReady else { return }
        currentURI = url.absoluteString
        documentVersion = 1
        send(notification: "textDocument/didOpen", params: [
            "textDocument": ["uri": currentURI, "languageId": "latex", "version": 1, "text": text]
        ])
    }

    func changeDocument(text: String) {
        guard isReady, !currentURI.isEmpty else { return }
        documentVersion += 1
        send(notification: "textDocument/didChange", params: [
            "textDocument": ["uri": currentURI, "version": documentVersion],
            "contentChanges": [["text": text]]
        ])
    }

    func requestCompletions(line: Int, character: Int) async -> [(label: String, insertText: String)] {
        guard isReady, !currentURI.isEmpty else { return [] }
        let id = nextID; nextID += 1
        return await withCheckedContinuation { cont in
            pendingCompletions[id] = cont
            send(request: id, method: "textDocument/completion", params: [
                "textDocument": ["uri": currentURI],
                "position": ["line": line, "character": character],
                "context": ["triggerKind": 1]
            ])
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        writer  = nil
        buffer.removeAll()
        initialized = false
        isReady = false
        currentURI = ""
        documentVersion = 1
        latestCompletions = []
        for continuation in pendingCompletions.values {
            continuation.resume(returning: [])
        }
        pendingCompletions.removeAll()
    }

    // MARK: - Send helpers

    private func send(request id: Int, method: String, params: Any) {
        sendRaw(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func send(notification method: String, params: Any) {
        sendRaw(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func sendRaw(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let w = writer else { return }
        w.write(Data("Content-Length: \(data.count)\r\n\r\n".utf8))
        w.write(data)
    }

    // MARK: - Read / parse

    private func flush() {
        let sep = Data([13, 10, 13, 10]) // \r\n\r\n
        while true {
            guard let sepRange = buffer.range(of: sep) else { break }
            let header = String(data: buffer[..<sepRange.lowerBound], encoding: .utf8) ?? ""
            guard let lenLine = header.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let len = Int(lenLine.dropFirst(15).trimmingCharacters(in: .whitespaces))
            else { buffer.removeAll(); break }
            let bodyStart = sepRange.upperBound
            guard buffer.count >= bodyStart + len else { break }
            let body = Data(buffer[bodyStart..<(bodyStart + len)])
            buffer.removeFirst(bodyStart + len)
            dispatch(body)
        }
    }

    private func dispatch(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = msg["method"] as? String {
            if method == "textDocument/publishDiagnostics" { handlePublishDiagnostics(msg["params"]) }
            return
        }

        guard msg["id"] != nil else { return }

        if !initialized {
            // initialize response
            initialized = true
            isReady = true
            send(notification: "initialized", params: [:] as [String: String])
            return
        }

        // Completion response
        if let idRaw = msg["id"] as? Int, let cont = pendingCompletions[idRaw] {
            pendingCompletions.removeValue(forKey: idRaw)
            let items = parseCompletions(msg["result"])
            latestCompletions = items
            cont.resume(returning: items)
        }
    }

    private func handlePublishDiagnostics(_ params: Any?) {
        guard let p = params as? [String: Any],
              let uri = p["uri"] as? String,
              let items = p["diagnostics"] as? [[String: Any]] else { return }
        let file = URL(string: uri)
        let diags: [Diagnostic] = items.compactMap { item in
            guard let message = item["message"] as? String,
                  let range = item["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line0 = start["line"] as? Int else { return nil }
            let sev = item["severity"] as? Int ?? 3
            let severity: DiagnosticSeverity = sev == 1 ? .error : sev == 2 ? .warning : .info
            return Diagnostic(source: .lsp, severity: severity, file: file, line: line0 + 1, message: message)
        }
        onDiagnostics?(diags)
    }

    private func parseCompletions(_ result: Any?) -> [(label: String, insertText: String)] {
        let arr: [[String: Any]]?
        if let list = result as? [String: Any] {
            arr = list["items"] as? [[String: Any]]
        } else {
            arr = result as? [[String: Any]]
        }
        return arr?.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            // texlab uses textEdit.newText; keep any $-snippet placeholders for the accept path.
            let insert = (item["insertText"] as? String)
                ?? ((item["textEdit"] as? [String: Any])?["newText"] as? String)
                ?? label
            return (label: label, insertText: insert)
        } ?? []
    }

    private func findTexlab() -> URL? {
        ["/opt/homebrew/bin/texlab", "/usr/local/bin/texlab"].first {
            FileManager.default.fileExists(atPath: $0)
        }.map { URL(filePath: $0) }
    }
}
#else
// iOS stub — no process spawning on iOS
import Foundation
import Observation

@MainActor
@Observable
final class TexLabClient {
    private(set) var latestCompletions: [(label: String, insertText: String)] = []
    private(set) var isReady = false
    var onDiagnostics: (([Diagnostic]) -> Void)?
    func start(workspaceURL: URL) {}
    func openDocument(url: URL, text: String) {}
    func changeDocument(text: String) {}
    func requestCompletions(line: Int, character: Int) async -> [(label: String, insertText: String)] { [] }
    func stop() {}
}
#endif
