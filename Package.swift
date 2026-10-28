// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Breeze",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Breeze",
            path: "Sources/Breeze"
        )
    ]
)
