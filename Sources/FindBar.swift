#if os(macOS)
import SwiftUI
import AppKit

/// Compact find/replace bar pinned above the editor. Drives the editor through the shared
/// `FindController`; the bar itself only reads match state for the counter.
struct FindBar: View {
    @ObservedObject var find: FindController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            findRow
            if find.showReplace { replaceRow }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true; selectAllSoon() }
        .onChange(of: find.focusPulse) { _, _ in focused = true; selectAllSoon() }
        .onExitCommand { find.hide() }
    }

    private var counter: String {
        if find.query.isEmpty { return "" }
        return find.matches.isEmpty ? "Not found" : "\(find.currentIndex + 1)/\(find.matches.count)"
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                // Plain Return → next via onSubmit (IME-safe); only intercept ⇧Return for prev.
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.prev(); return .handled
                }
                .onSubmit { find.next() }
                .frame(minWidth: 140, maxWidth: 280)

            if !counter.isEmpty {
                Text(counter)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 14)

            Toggle(isOn: $find.caseSensitive) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Match case")

            Button { find.prev() } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
            Button { find.hide() } label: { Image(systemName: "xmark.circle.fill") }
                .help("Close (Esc)")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Replace", text: $find.replacement)
                .textFieldStyle(.plain)
                .onSubmit { find.replaceOnce() }
                .frame(minWidth: 140, maxWidth: 280)

            Divider().frame(height: 14)

            Button("Replace") { find.replaceOnce() }
                .help("Replace the current match")
            Button("All") { find.replaceAll() }
                .help("Replace all matches")
        }
        .font(.caption)
    }

    /// Pull keyboard focus into the search field, then select its text so overtyping replaces it.
    /// SwiftUI's FocusState alone won't wrest first responder from the editor NSTextView, so keep
    /// resigning it and re-asserting focus until the field editor lands (qmd's quick-open pattern).
    /// Guarded: selectAll must only ever hit a field editor — sent to the editor it would
    /// select the whole document and the next keystroke would replace it.
    private func selectAllSoon(_ attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.03)) {
            guard let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.isFieldEditor else {
                if attempt < 20 {
                    if let w = NSApp.keyWindow, let tv = w.firstResponder as? NSTextView, !tv.isFieldEditor {
                        w.makeFirstResponder(nil)
                    }
                    focused = true
                    selectAllSoon(attempt + 1)
                }
                return
            }
            fr.selectAll(nil)
        }
    }
}
#endif
