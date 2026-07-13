import SwiftUI

/// App-wide editor font zoom. A single shared instance so every open window zooms together
/// and the choice survives across launches (persisted in UserDefaults). ⌘+ / ⌘- step it;
/// ⌘0 resets to 1.0.
final class FontScale: ObservableObject {
    static let shared = FontScale()

    static let baseSize: CGFloat = 13
    static let minScale = 0.7
    static let maxScale = 2.0
    private static let step = 0.1
    private static let key = "itex.fontScale"

    @Published private(set) var scale: Double

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        scale = (stored >= Self.minScale && stored <= Self.maxScale) ? stored : 1.0
    }

    private func set(_ value: Double) {
        let clamped = min(Self.maxScale, max(Self.minScale, (value * 10).rounded() / 10))
        guard clamped != scale else { return }
        scale = clamped
        UserDefaults.standard.set(clamped, forKey: Self.key)
    }

    func zoomIn()  { set(scale + Self.step) }
    func zoomOut() { set(scale - Self.step) }
    func reset()   { set(1.0) }
}
