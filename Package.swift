// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PerchCore", swiftSettings: swift5),
        .executableTarget(name: "Perch", dependencies: ["PerchCore"], swiftSettings: swift5),
        .testTarget(name: "PerchCoreTests", dependencies: ["PerchCore"], swiftSettings: swift5),
    ]
)
