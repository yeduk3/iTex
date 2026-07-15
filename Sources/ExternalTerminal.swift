#if os(macOS)
import AppKit
import SwiftUI

/// Known external terminal applications. Automatic deliberately prefers Ghostty, then the
/// system Terminal, so a default install works without another preference step.
enum ExternalTerminalPreference: String, CaseIterable, Identifiable {
    case automatic
    case ghostty
    case terminal
    case iTerm2
    case warp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .ghostty:   return "Ghostty"
        case .terminal:  return "Terminal"
        case .iTerm2:    return "iTerm2"
        case .warp:      return "Warp"
        }
    }

    fileprivate var bundleIdentifiers: [String] {
        switch self {
        case .automatic: return []
        case .ghostty:   return ["com.mitchellh.ghostty"]
        case .terminal:  return ["com.apple.Terminal"]
        case .iTerm2:    return ["com.googlecode.iterm2"]
        // Warp has shipped under both identifiers.
        case .warp:      return ["dev.warp.Warp-Stable", "app.warp.Warp-Stable"]
        }
    }
}

@MainActor
enum ExternalTerminalLauncher {
    static let preferenceKey = "externalTerminalApplication"

    struct Resolution {
        let preference: ExternalTerminalPreference
        let applicationURL: URL
    }

    static var selectedPreference: ExternalTerminalPreference {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        return raw.flatMap(ExternalTerminalPreference.init(rawValue:)) ?? .automatic
    }

    static func installedApplication(for preference: ExternalTerminalPreference) -> URL? {
        preference.bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    static func isInstalled(_ preference: ExternalTerminalPreference) -> Bool {
        preference == .automatic || installedApplication(for: preference) != nil
    }

    static func resolvedApplication(for preference: ExternalTerminalPreference? = nil) -> Resolution? {
        let requested = preference ?? selectedPreference
        if requested != .automatic {
            return installedApplication(for: requested).map {
                Resolution(preference: requested, applicationURL: $0)
            }
        }
        // Terminal is intentionally ahead of optional alternatives as the reliable system fallback.
        for candidate in [ExternalTerminalPreference.ghostty, .terminal, .iTerm2, .warp] {
            if let url = installedApplication(for: candidate) {
                return Resolution(preference: candidate, applicationURL: url)
            }
        }
        return nil
    }

    static func open(directory: URL) {
        let directory = directory.standardizedFileURL
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw LaunchError.notDirectory(directory)
            }
            guard let resolution = resolvedApplication() else {
                throw LaunchError.notInstalled(selectedPreference)
            }
            launch(directory: directory, with: resolution)
        } catch {
            presentFailure(error)
        }
    }

    private static func launch(directory: URL, with resolution: Resolution) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        configuration.addsToRecentItems = false

        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
            guard error != nil || application == nil else { return }
            Task { @MainActor in presentFailure(error ?? LaunchError.launchFailed) }
        }

        if resolution.preference == .ghostty {
            // NSWorkspace's new-instance + arguments path is the API equivalent of:
            // open -na Ghostty.app --args --working-directory=<path>
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = ["--working-directory=\(directory.path)"]
            NSWorkspace.shared.openApplication(
                at: resolution.applicationURL,
                configuration: configuration,
                completionHandler: completion)
        } else {
            // Terminal, iTerm2 and Warp register as folder handlers and receive the directory URL.
            NSWorkspace.shared.open(
                [directory],
                withApplicationAt: resolution.applicationURL,
                configuration: configuration,
                completionHandler: completion)
        }
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t Open Terminal"
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private enum LaunchError: LocalizedError {
        case notDirectory(URL)
        case notInstalled(ExternalTerminalPreference)
        case launchFailed

        var errorDescription: String? {
            switch self {
            case .notDirectory(let url):
                return "“\(url.path)” is not an available project folder. Save the document and try again."
            case .notInstalled(.automatic):
                return "No supported terminal application was found. Install Ghostty or use Terminal."
            case .notInstalled(let preference):
                return "\(preference.displayName) is not installed. Choose another terminal in Settings."
            case .launchFailed:
                return "The terminal application did not launch. Choose another terminal in Settings and try again."
            }
        }
    }
}

struct ProjectDirectoryKey: FocusedValueKey { typealias Value = URL }

extension FocusedValues {
    var projectDirectory: URL? {
        get { self[ProjectDirectoryKey.self] }
        set { self[ProjectDirectoryKey.self] = newValue }
    }
}
#endif
