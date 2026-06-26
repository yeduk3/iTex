import SwiftUI
import PDFKit

/// Page-height lookup for SyncTeX Y-flip (docs/04 §4.3).
struct PDFPageHeights {
    private let doc: PDFDocument?
    init(url: URL) { doc = PDFDocument(url: url) }
    func height(page oneBased: Int) -> CGFloat {
        guard let doc, let p = doc.page(at: oneBased - 1) else { return 792 }
        return p.bounds(for: .mediaBox).height
    }
}

struct PDFPreviewView: View {
    let compiler: LaTeXCompiler

    var body: some View {
        Group {
            if let url = compiler.pdfURL {
                PDFKitRepresentable(url: url, compiler: compiler)
            } else if compiler.isCompiling {
                ProgressView("Compiling…")
            } else {
                ContentUnavailableView(
                    "No Preview",
                    systemImage: "doc.richtext",
                    description: Text("Write LaTeX and save to generate PDF")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - macOS

#if os(macOS)
private struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL
    let compiler: LaTeXCompiler

    func makeCoordinator() -> Coordinator { Coordinator(compiler: compiler) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        context.coordinator.view = view

        // ⌘-click in the PDF → inverse search (docs/04 §4.3).
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coord = context.coordinator
        coord.compiler = compiler

        // Reload only on a new compile, preserving scroll + zoom (C7, docs/02).
        if coord.lastCompilationID != compiler.compilationID {
            coord.lastCompilationID = compiler.compilationID
            let scale = view.scaleFactor
            let dest = view.currentDestination
            view.document = PDFDocument(url: url)
            view.scaleFactor = scale
            if let dest { view.go(to: dest) }
        }

        // Apply a forward-search highlight when a new one arrives.
        if let fh = compiler.forwardHighlight, fh.token != coord.lastForwardToken {
            coord.lastForwardToken = fh.token
            coord.showHighlight(fh)
        }
    }

    final class Coordinator: NSObject {
        weak var view: PDFView?
        var compiler: LaTeXCompiler
        var lastCompilationID = -1
        var lastForwardToken = -1
        private var added: [(PDFPage, PDFAnnotation)] = []

        init(compiler: LaTeXCompiler) { self.compiler = compiler }

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard NSEvent.modifierFlags.contains(.command),
                  let view, let doc = view.document else { return }
            let p = g.location(in: view)
            guard let page = view.page(for: p, nearest: true) else { return }
            let pageIndex = doc.index(for: page)
            let local = view.convert(p, to: page)
            let height = page.bounds(for: .mediaBox).height
            Task { @MainActor in
                await compiler.inverseSearch(page: pageIndex + 1, point: local, pageHeight: height)
            }
        }

        @MainActor func showHighlight(_ fh: ForwardHighlight) {
            guard let view, let doc = view.document, let page = doc.page(at: fh.page - 1) else { return }
            for (pg, ann) in added { pg.removeAnnotation(ann) }
            added.removeAll()
            for rect in fh.rects {
                let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                ann.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(ann)
                added.append((page, ann))
            }
            if let first = fh.rects.first {
                view.go(to: PDFDestination(page: page, at: CGPoint(x: first.minX, y: first.maxY)))
            }
        }
    }
}

// MARK: - iOS (no inverse search; viewport preserved)

#else
private struct PDFKitRepresentable: UIViewRepresentable {
    let url: URL
    let compiler: LaTeXCompiler

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.lastCompilationID != compiler.compilationID {
            context.coordinator.lastCompilationID = compiler.compilationID
            let scale = view.scaleFactor
            let dest = view.currentDestination
            view.document = PDFDocument(url: url)
            view.scaleFactor = scale
            if let dest { view.go(to: dest) }
        }
    }

    final class Coordinator { var lastCompilationID = -1 }
}
#endif
