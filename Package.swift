// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceTap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceTap",
            path: "Sources/VoiceTap"
        )
    ]
)
