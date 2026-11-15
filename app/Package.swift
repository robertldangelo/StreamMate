// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StreamMate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "StreamMate", path: "Sources/StreamMate")
    ]
)
