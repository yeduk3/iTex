import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

/// A user-assignable key combo. Stored as a base character + modifier flags so it converts to both
/// a SwiftUI `KeyboardShortcut` (for buttons) and an `NSEvent` match (for the editor).
struct KeyCombo: Codable, Equatable {
    var key: String          // base character, lowercased (e.g. "b", "/", ".")
    var command = true
    var shift = false
    var option = false
    var control = false

    init(key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key.first ?? " "), modifiers: eventModifiers)
    }

#if os(macOS)
    /// Build from a recorded key-down event; nil for modifier-only presses or no real modifier.
    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let ch = chars.first, !ch.isWhitespace else { return nil }
        let f = event.modifierFlags
        let cmd = f.contains(.command), ctrl = f.contains(.control), opt = f.contains(.option)
        guard cmd || ctrl || opt else { return nil }   // a shortcut needs a non-shift modifier
        self.init(key: String(ch), command: cmd, shift: f.contains(.shift), option: opt, control: ctrl)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars == key else { return false }
        let f = event.modifierFlags
        return f.contains(.command) == command && f.contains(.shift) == shift
            && f.contains(.option) == option && f.contains(.control) == control
    }
#endif
}

/// Every command whose shortcut the user can reassign (toolbar buttons + editor features).
enum AppCommand: String, CaseIterable, Identifiable {
    case build, forwardSync, scrollSyncToggle, toggleComment, showError

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build:            return "Build (full compile)"
        case .forwardSync:      return "Jump to cursor in PDF"
        case .scrollSyncToggle: return "Toggle scroll sync"
        case .toggleComment:    return "Toggle line comment"
        case .showError:        return "Show error message"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .build:            return KeyCombo(key: "b")
        case .forwardSync:      return KeyCombo(key: "j")
        case .scrollSyncToggle: return KeyCombo(key: "s", command: true, control: true)
        case .toggleComment:    return KeyCombo(key: "/")
        case .showError:        return KeyCombo(key: ".")
        }
    }
}

/// Persisted shortcut assignments (UserDefaults). Observable so the UI + toolbar react to edits.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private var combos: [String: KeyCombo] = [:]
    private let storeKey = "shortcuts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            combos = decoded
        }
    }

    func combo(_ c: AppCommand) -> KeyCombo { combos[c.id] ?? c.defaultCombo }

    func set(_ combo: KeyCombo, for c: AppCommand) { combos[c.id] = combo; persist() }
    func reset(_ c: AppCommand) { combos[c.id] = nil; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(combos) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

#if os(macOS)
    /// The command (if any) whose assigned combo matches this event.
    func command(for event: NSEvent) -> AppCommand? {
        AppCommand.allCases.first { combo($0).matches(event) }
    }
#endif
}
