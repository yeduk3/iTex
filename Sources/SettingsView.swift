#if os(macOS)
import SwiftUI
import AppKit

/// Preferences window (⌘,). Lists every reassignable command with a recorder + reset.
struct ShortcutSettingsView: View {
    @State private var store = ShortcutStore.shared
    @AppStorage("previewSplitVertical") private var verticalSplit = false

    var body: some View {
        Form {
            Section {
                Picker("Editor / Preview layout", selection: $verticalSplit) {
                    Text("Side by side").tag(false)
                    Text("Stacked (vertical)").tag(true)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Layout")
            }

            Section {
                ForEach(AppCommand.allCases) { cmd in
                    HStack(spacing: 12) {
                        Text(cmd.title)
                        Spacer()
                        ShortcutRecorder(combo: Binding(
                            get: { store.combo(cmd) },
                            set: { store.set($0, for: cmd) }))
                        Button("Reset") { store.reset(cmd) }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new keys. Esc cancels. A modifier (⌘/⌃/⌥) is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 340)
    }
}

/// Click to record: captures the next key-down as a `KeyCombo`.
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Type shortcut…" : combo.display)
                .frame(minWidth: 96)
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }          // Esc cancels
            if let c = KeyCombo(event: event) { combo = c; stop() }  // ignores modifier-only presses
            return nil                                              // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
#endif
