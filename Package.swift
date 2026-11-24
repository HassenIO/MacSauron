// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacSauron",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacSauron", path: "Sources/MacSauron")
    ]
)
