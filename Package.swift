// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IvyVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "IvyVoice",
            path: "Sources/IvyVoice"
        )
    ]
)
