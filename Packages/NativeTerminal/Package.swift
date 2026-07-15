// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeTerminal",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "NativeTerminal", targets: ["NativeTerminal"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            .upToNextMinor(from: "1.14.0"))
    ],
    targets: [
        .target(
            name: "NativeTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ])
    ]
)
