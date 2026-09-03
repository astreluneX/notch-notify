// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchNotify",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchNotify",
            path: "Sources/NotchNotify"
        )
    ]
)
