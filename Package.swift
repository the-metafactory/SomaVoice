// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SomaVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SomaVoice",
            path: "Sources/SomaVoice"
        )
    ]
)
