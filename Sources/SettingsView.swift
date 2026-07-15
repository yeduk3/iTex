#if os(macOS)
import SwiftUI
import AppKit

/// Preferences window (⌘,). Lists every reassignable command with a recorder + reset.
struct ShortcutSettingsView: View {
    @State private var store = ShortcutStore.shared
    @AppStorage("previewSplitVertical") private var verticalSplit = false
    @AppStorage("editorTabWidth") private var tabWidth = 2
    @AppStorage(ExternalTerminalLauncher.preferenceKey) private var terminalPreference = ExternalTerminalPreference.automatic.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Editor / Preview layout", selection: $verticalSplit) {
                    Text("Side by side").tag(false)
                    Text("Stacked (vertical)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Stepper(value: $tabWidth, in: 1...8) {
                    Text("Tab width: \(tabWidth) spaces")
                }
            } header: {
                Text("Layout")
            }

            Section {
                Picker("Terminal application", selection: $terminalPreference) {
                    ForEach(ExternalTerminalPreference.allCases) { terminal in
                        let installed = ExternalTerminalLauncher.isInstalled(terminal)
                        Text(terminal.displayName + (installed ? "" : " — Not installed"))
                            .tag(terminal.rawValue)
                            .disabled(!installed)
                    }
                }

                terminalResolution
                    .font(.caption)
            } header: {
                Text("Terminal")
            } footer: {
                Text("Automatic prefers Ghostty and falls back to the system Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 480, height: 440)
    }

    @ViewBuilder
    private var terminalResolution: some View {
        let selected = ExternalTerminalPreference(rawValue: terminalPreference) ?? .automatic
        if let resolved = ExternalTerminalLauncher.resolvedApplication(for: selected) {
            if selected == .automatic {
                Text("Currently resolves to \(resolved.preference.displayName).")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(resolved.preference.displayName) is installed and ready.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("\(selected.displayName) is not installed. Choose an available terminal.")
                .foregroundStyle(.red)
        }
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
