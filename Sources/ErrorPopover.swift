#if os(macOS)
import AppKit

/// Small popover shown on hover / ⌘. over an error line: scrollable message + a copy button.
final class ErrorPopover: NSObject {
    private let popover = NSPopover()
    private let messageView = NSTextView()
    private var scrollHeight: NSLayoutConstraint!
    private var message = ""
    private(set) var currentLine: Int?

    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        popover.behavior = .semitransient   // closes on outside click, but NOT on the ⌘. keystroke that opens it
        popover.contentViewController = makeViewController()
    }

    func show(message: String, line: Int, lineRect: NSRect, in view: NSView) {
        self.message = message
        currentLine = line
        messageView.string = message

        // Clamp the scroll height: show a few lines, scroll the rest.
        messageView.layoutManager?.ensureLayout(for: messageView.textContainer!)
        let textH = messageView.layoutManager?.usedRect(for: messageView.textContainer!).height ?? 40
        scrollHeight.constant = min(max(textH + 8, 34), 120)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()

        if popover.isShown { popover.close() }   // re-anchor to the new line
        guard lineRect != .zero else { return }
        popover.show(relativeTo: lineRect, of: view, preferredEdge: .maxY)
    }

    func close() {
        currentLine = nil
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    private func makeViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        messageView.isEditable = false
        messageView.drawsBackground = false
        messageView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        messageView.textContainerInset = NSSize(width: 4, height: 4)
        messageView.isVerticallyResizable = true
        messageView.isHorizontallyResizable = false
        messageView.autoresizingMask = [.width]
        messageView.minSize = .zero
        messageView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        messageView.textContainer?.widthTracksTextView = true
        scroll.documentView = messageView

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyMessage))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(copyButton)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollHeight,
            copyButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        vc.view = root
        return vc
    }
}

/// Popover showing a thumbnail of the image referenced on a line (⌘. when the line has no error).
final class ImagePreviewPopover: NSObject {
    private let popover = NSPopover()
    private let imageView = NSImageView()
    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!
    private(set) var currentLine: Int?

    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        popover.behavior = .semitransient
        popover.contentViewController = makeViewController()
    }

    func show(image: NSImage, line: Int, lineRect: NSRect, in view: NSView) {
        currentLine = line
        imageView.image = image
        // Fit into a max box while keeping aspect; never upscale past native size.
        let maxSide: CGFloat = 360
        let s = image.size
        let scale = min(maxSide / max(s.width, 1), maxSide / max(s.height, 1), 1)
        widthC.constant  = max(s.width * scale, 32)
        heightC.constant = max(s.height * scale, 32)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()

        if popover.isShown { popover.close() }   // re-anchor to the new line
        guard lineRect != .zero else { return }
        popover.show(relativeTo: lineRect, of: view, preferredEdge: .maxY)
    }

    func close() {
        currentLine = nil
        if popover.isShown { popover.performClose(nil) }
    }

    private func makeViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(imageView)
        widthC  = imageView.widthAnchor.constraint(equalToConstant: 200)
        heightC = imageView.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            widthC, heightC,
        ])
        vc.view = root
        return vc
    }
}
#endif
