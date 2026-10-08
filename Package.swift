// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(name: "Tether", path: "Sources/Tether")
    ]
)
