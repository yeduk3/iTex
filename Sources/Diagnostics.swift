import Foundation
import Combine

enum DiagnosticSource: String {
    case build, chktex, lsp
    var tag: String {
        switch self {
        case .build:  return "Build"
        case .chktex: return "Lint"
        case .lsp:    return "LSP"
        }
    }
}

enum DiagnosticSeverity: Int {
    case error = 0, warning = 1, info = 2
    var symbol: String {
        switch self {
        case .error:   return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle"
        }
    }
}

struct Diagnostic: Identifiable {
    let id = UUID()
    let source: DiagnosticSource
    let severity: DiagnosticSeverity
    let file: URL?
    let line: Int
    let message: String
}

/// Per-window store: three independent buckets, each replaced wholesale by its producer.
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var build: [Diagnostic] = []
    @Published private(set) var chktex: [Diagnostic] = []
    @Published private(set) var lsp: [Diagnostic] = []

    func setBuild(_ d: [Diagnostic])  { build = d }
    func setChkTex(_ d: [Diagnostic]) { chktex = d }
    func setLSP(_ d: [Diagnostic])    { lsp = d }

    /// Errors first, then by file path + line.
    var all: [Diagnostic] {
        (build + chktex + lsp).sorted { a, b in
            if a.severity != b.severity { return a.severity.rawValue < b.severity.rawValue }
            let fa = a.file?.path ?? "", fb = b.file?.path ?? ""
            if fa != fb { return fa < fb }
            return a.line < b.line
        }
    }

    func count(_ s: DiagnosticSeverity) -> Int {
        (build + chktex + lsp).lazy.filter { $0.severity == s }.count
    }
}

#if os(macOS)
import SwiftUI

extension DiagnosticSeverity {
    var color: Color {
        switch self {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .secondary
        }
    }
}

/// Collapsible bottom panel listing every diagnostic from all producers; a row click jumps to it.
struct ProblemsPanel: View {
    @ObservedObject var store: DiagnosticsStore
    let onJump: (Diagnostic) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            let items = store.all
            if items.isEmpty {
                HStack {
                    Text("No problems").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { d in
                            Button { onJump(d) } label: { ProblemRow(diagnostic: d) }
                                .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(height: 170)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ProblemRow: View {
    let diagnostic: Diagnostic
    private var location: String {
        (diagnostic.file?.lastPathComponent).map { "\($0):\(diagnostic.line)" } ?? "line \(diagnostic.line)"
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: diagnostic.severity.symbol)
                .foregroundStyle(diagnostic.severity.color)
            Text(diagnostic.source.tag)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(location)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(diagnostic.message)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(diagnostic.message)
    }
}

struct ProblemsToggleKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var problemsToggle: (() -> Void)? {
        get { self[ProblemsToggleKey.self] }
        set { self[ProblemsToggleKey.self] = newValue }
    }
}
#endif
