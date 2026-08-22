// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crossover",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Crossover",
            path: "Sources/Crossover",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
