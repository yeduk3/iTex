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
                // Pass the forward-search request so SwiftUI re-runs updateNSView when it changes.
                PDFKitRepresentable(url: url, compiler: compiler, forward: compiler.forwardHighlight)
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
    let forward: ForwardHighlight?   // diffed by SwiftUI so updateNSView fires on new forward searches

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
        coord.view = view
        coord.attachScrollObserver()   // idempotent; internal scroll view exists once laid out

        // Reload only on a new compile, preserving scroll + zoom (C7, docs/02).
        if coord.lastCompilationID != compiler.compilationID {
            coord.lastCompilationID = compiler.compilationID
            let scale = view.scaleFactor
            // currentDestination's page belongs to the OLD document; go(to:) can't match it
            // after the swap and snaps to the top. Re-anchor by page index into the new doc.
            let dest = view.currentDestination
            let pageIndex = dest.flatMap { d -> Int? in
                guard let p = d.page else { return nil }
                let i = view.document?.index(for: p) ?? NSNotFound
                return i == NSNotFound ? nil : i
            }
            view.document = PDFDocument(url: url)
            view.scaleFactor = scale
            if let dest, let pageIndex, let page = view.document?.page(at: pageIndex) {
                compiler.beginSyncCooldown()   // restored scroll must not echo to the editor via scroll-sync
                view.go(to: PDFDestination(page: page, at: dest.point))
            }
        }

        // Apply a forward-search highlight (manual ⌘J or scroll-sync) — center it.
        if let fh = compiler.forwardHighlight, fh.token != coord.lastForwardToken {
            coord.lastForwardToken = fh.token
            coord.centerOnForward(fh)
        }
    }

    final class Coordinator: NSObject {
        weak var view: PDFView?
        var compiler: LaTeXCompiler
        var lastCompilationID = -1
        var lastForwardToken = -1
        private var observing = false
        private var scrollWork: DispatchWorkItem?

        init(compiler: LaTeXCompiler) { self.compiler = compiler }

        private func internalScroll() -> NSScrollView? {
            view?.subviews.compactMap { $0 as? NSScrollView }.first
        }

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

        /// Center the PDF viewport on the forward-search rect, clamped to the document.
        @MainActor func centerOnForward(_ fh: ForwardHighlight) {
            guard let view, let doc = view.document, let page = doc.page(at: fh.page - 1),
                  let first = fh.rects.first else { return }
            compiler.beginSyncCooldown()   // our own scroll must not echo back via scroll-sync
            center(on: CGRect(x: first.minX, y: first.minY, width: first.width, height: first.height), page: page, view: view)
        }

        @MainActor private func center(on rect: CGRect, page: PDFPage, view: PDFView) {
            // Animate the internal scroll view's clip so the target rect lands at the viewport
            // center (clamped to the document). Falls back to PDFKit's instant go(to:) if the
            // internal scroll view isn't available.
            guard let scroll = internalScroll(), let docView = scroll.documentView else {
                let halfViewport = (view.visibleRect.height / max(view.scaleFactor, 0.01)) / 2
                view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.midY + halfViewport)))
                return
            }
            let pageCenter = CGPoint(x: rect.midX, y: rect.midY)
            let inDoc = docView.convert(view.convert(pageCenter, from: page), from: view)
            let clip = scroll.contentView
            let visH = clip.bounds.height, visW = clip.bounds.width
            var origin = CGPoint(x: inDoc.x - visW / 2, y: inDoc.y - visH / 2)
            origin.x = min(max(origin.x, 0), max(0, docView.bounds.width - visW))
            origin.y = min(max(origin.y, 0), max(0, docView.bounds.height - visH))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(clip)
            }
        }

        // MARK: scroll-sync (PDF → editor)

        func attachScrollObserver() {
            guard !observing, let scroll = internalScroll() else { return }
            observing = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(pdfScrolled),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @MainActor @objc private func pdfScrolled() {
            guard compiler.scrollSyncEnabled, !compiler.inSyncCooldown else { return }
            scrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.syncCenterToEditor() } }
            scrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }

        @MainActor private func syncCenterToEditor() {
            guard compiler.scrollSyncEnabled, !compiler.inSyncCooldown,
                  let view, let doc = view.document, let scroll = internalScroll() else { return }
            let clip = scroll.contentView
            let inView = view.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
            guard let page = view.page(for: inView, nearest: true) else { return }
            let local = view.convert(inView, to: page)
            let pageIndex = doc.index(for: page)
            let height = page.bounds(for: .mediaBox).height
            Task { @MainActor in await compiler.syncPDFToEditor(page: pageIndex + 1, point: local, pageHeight: height) }
        }
    }
}

// MARK: - iOS (no inverse search; viewport preserved)

#else
private struct PDFKitRepresentable: UIViewRepresentable {
    let url: URL
    let compiler: LaTeXCompiler
    let forward: ForwardHighlight?   // unused on iOS (no SyncTeX); keeps the shared call site uniform

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
            // Re-anchor by page index: currentDestination's page is from the old doc (see macOS).
            let dest = view.currentDestination
            let pageIndex = dest.flatMap { d -> Int? in
                guard let p = d.page else { return nil }
                let i = view.document?.index(for: p) ?? NSNotFound
                return i == NSNotFound ? nil : i
            }
            view.document = PDFDocument(url: url)
            view.scaleFactor = scale
            if let dest, let pageIndex, let page = view.document?.page(at: pageIndex) {
                view.go(to: PDFDestination(page: page, at: dest.point))
            }
        }
    }

    final class Coordinator { var lastCompilationID = -1 }
}
#endif
