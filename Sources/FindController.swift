import Foundation
import Combine

/// Per-window source of truth for the in-file find/replace bar. The editor coordinator
/// observes it through `updateNSView` and performs the literal search over the text storage.
final class FindController: ObservableObject {
    @Published var isVisible = false
    @Published var showReplace = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var caseSensitive: Bool { didSet { UserDefaults.standard.set(caseSensitive, forKey: Self.caseKey) } }

    /// Match ranges + active index, written back by the coordinator for the bar's counter.
    @Published var matches: [NSRange] = []
    @Published var currentIndex = 0

    /// Bumped to request navigation; `backwards` picks direction.
    @Published var navToken = 0
    var backwards = false
    /// Bumped to pull keyboard focus into the search field (⌘F, and ⌘F while already open).
    @Published var focusPulse = 0
    /// Bumped to request a replace; `replaceAllRequested` distinguishes once vs all.
    @Published var replaceToken = 0
    private(set) var replaceAllRequested = false

    private static let caseKey = "findCaseSensitive"

    init() { caseSensitive = UserDefaults.standard.bool(forKey: Self.caseKey) }

    func show() { isVisible = true; focusPulse &+= 1 }
    func toggleReplace() { showReplace.toggle(); if showReplace { show() } }
    func hide() {
        isVisible = false; showReplace = false
        query = ""; replacement = ""
        matches = []; currentIndex = 0
    }
    func next() { backwards = false; navToken &+= 1 }
    func prev() { backwards = true; navToken &+= 1 }
    func replaceOnce() { replaceAllRequested = false; replaceToken &+= 1 }
    func replaceAll() { replaceAllRequested = true; replaceToken &+= 1 }
}
