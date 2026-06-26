import SwiftUI

struct EditorView: View {
    @Binding var source: String
    let compiler: LaTeXCompiler
    let linter: ChkTexLinter
    var texLabClient: TexLabClient?

    var body: some View {
        VStack(spacing: 0) {
            if let msg = compiler.errorMessage {
                banner(msg, color: .red)
            }
            LaTeXEditorView(text: $source, texLabClient: texLabClient, compiler: compiler)
                .onChange(of: source) { _, new in
                    compiler.scheduleCompile(source: new)
                    linter.scheduleLint(fileURL: compiler.fileURL)
                    texLabClient?.changeDocument(text: new)
                }
        }
    }

    private func banner(_ message: String, color: Color) -> some View {
        ScrollView(.vertical) {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(maxHeight: 90)
        .background(color.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }
}
