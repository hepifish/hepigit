// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hepigit",
    platforms: [.macOS(.v15)],
    
    targets: [
        .executableTarget(
            name: "Hepigit",
            path: "Sources/Hepigit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
