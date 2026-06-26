// swift-tools-version:5.9
import PackageDescription

// `itex` — minimal CLI that reuses iTex's compile engine so one binary can back both the
// native app and a VSCode / texlab build recipe (docs/04 §4.5). The engine sources are
// symlinked in from ../Sources so there is a single source of truth.
let package = Package(
    name: "itex",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "itex", path: "Sources/itex")
    ]
)
