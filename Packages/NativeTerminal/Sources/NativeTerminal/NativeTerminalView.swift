import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// Configuration for one local terminal process. Changing a live representable's configuration
/// does not restart it; recreate the view (for example with a new SwiftUI identity) for a new session.
public struct NativeTerminalConfiguration: Equatable, Sendable {
    public var workingDirectory: URL
    public var executable: String?
    public var arguments: [String]
    /// Values merged over the host process environment when non-nil.
    public var environment: [String: String]?

    public init(
        workingDirectory: URL,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// A single-session SwiftUI local terminal. It starts once when its NSView is created and
/// terminates the child process when SwiftUI dismantles the representable.
public struct NativeTerminalView: NSViewRepresentable {
    public let configuration: NativeTerminalConfiguration
    public let onCloseRequest: (() -> Void)?
    public let focusRequest: Int

    public init(
        configuration: NativeTerminalConfiguration,
        onCloseRequest: (() -> Void)? = nil,
        focusRequest: Int = 0
    ) {
        self.configuration = configuration
        self.onCloseRequest = onCloseRequest
        self.focusRequest = focusRequest
    }

    public final class Coordinator {
        fileprivate var lastHandledFocusRequest: Int?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Give the PTY a useful initial grid before SwiftUI's first layout pass resizes the view.
        let terminal = AppearanceAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 230))
        terminal.onCloseRequest = onCloseRequest
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.applyNativeAppearance()

        let executable = configuration.executable ?? LoginShell.resolve()
        terminal.startProcess(
            executable: executable,
            args: configuration.arguments,
            environment: processEnvironment(overrides: configuration.environment),
            execName: configuration.executable == nil ? "-\(URL(fileURLWithPath: executable).lastPathComponent)" : nil,
            currentDirectory: configuration.workingDirectory.standardizedFileURL.path)
        context.coordinator.lastHandledFocusRequest = focusRequest
        requestFocus(for: terminal)
        return terminal
    }

    public func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        // Semantic NSColors adapt to appearance changes; never restart a live process here.
        guard let terminal = terminal as? AppearanceAwareTerminalView else { return }
        terminal.onCloseRequest = onCloseRequest
        terminal.applyNativeAppearance()
        if context.coordinator.lastHandledFocusRequest != focusRequest {
            context.coordinator.lastHandledFocusRequest = focusRequest
            requestFocus(for: terminal)
        }
    }

    public static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        terminal.terminate()
    }

    private func processEnvironment(overrides: [String: String]?) -> [String]? {
        guard let overrides else { return nil } // let SwiftTerm supply its terminal-safe defaults
        var environment = ProcessInfo.processInfo.environment
        environment.merge(overrides) { _, override in override }
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        return environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    }

    private func requestFocus(for terminal: LocalProcessTerminalView) {
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

private final class AppearanceAwareTerminalView: LocalProcessTerminalView {
    var onCloseRequest: (() -> Void)?

    func applyNativeAppearance() {
        guard terminal != nil else { return } // appearance callbacks can arrive during NSView init
        nativeForegroundColor = .textColor
        nativeBackgroundColor = .textBackgroundColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyNativeAppearance()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(shortcutModifiers)
        let firstResponder = window?.firstResponder as? NSView
        let ownsFocus = firstResponder === self || firstResponder?.isDescendant(of: self) == true
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w", ownsFocus else {
            return super.performKeyEquivalent(with: event)
        }

        // Defer host state changes until AppKit finishes dispatching the current key event.
        let request = onCloseRequest
        DispatchQueue.main.async { request?() }
        return true
    }
}

private enum LoginShell {
    static func resolve() -> String {
        if let shell = usable(ProcessInfo.processInfo.environment["SHELL"]) { return shell }
        if let account = getpwuid(getuid()), let shell = usable(String(cString: account.pointee.pw_shell)) {
            return shell
        }
        return usable("/bin/zsh") ?? "/bin/sh"
    }

    private static func usable(_ candidate: String?) -> String? {
        guard let candidate, candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return candidate
    }
}
