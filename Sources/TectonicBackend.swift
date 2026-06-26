// In-process Tectonic backend (docs/03 §3.7, docs/04 §4.1) — the only backend that works on iOS,
// where Process spawning is forbidden. Also a warm in-process option on macOS.
//
// Guarded by ITEX_TECTONIC so the app builds with zero extra deps until the static lib is linked.
// To enable: build the lib (tectonic-ffi/build-macos.sh / build-xcframework.sh), add the
// XCFramework + module map to the target, and define ITEX_TECTONIC in SWIFT_ACTIVE_COMPILATION_CONDITIONS.

#if ITEX_TECTONIC
import Foundation
#if canImport(CItexTectonic)
import CItexTectonic
#endif

struct TectonicBackend: CompileBackend {
    func compile(texPath: URL, workingDir: URL, engine: TexEngine, profile: CompileProfile) async throws -> CompileResult {
        let source = try String(contentsOf: texPath, encoding: .utf8)
        let pdf = try Self.latexToPDF(source)
        let out = workingDir.appending(path: texPath.deletingPathExtension().lastPathComponent + ".pdf")
        try pdf.write(to: out)
        // SyncTeX from Tectonic: pass --synctex via the V2 driver (TODO when wiring the local bundle).
        return CompileResult(pdfURL: out, synctexURL: nil, log: "tectonic in-process (\(pdf.count) bytes)")
    }

    /// Bridges to the Rust FFI (itex_tectonic_compile / itex_tectonic_free).
    static func latexToPDF(_ latex: String) throws -> Data {
        let bytes = Array(latex.utf8)
        var outLen = 0
        let ptr: UnsafeMutablePointer<UInt8>? = bytes.withUnsafeBufferPointer { buf in
            itex_tectonic_compile(buf.baseAddress, buf.count, &outLen)
        }
        guard let ptr, outLen > 0 else {
            throw CompilerError.buildFailed("Tectonic in-process compile failed (check the bundled TeXLive bundle).")
        }
        defer { itex_tectonic_free(ptr, outLen) }
        return Data(bytes: ptr, count: outLen)
    }
}
#endif
