// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CaretTrail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CaretTrail", path: "Sources/CaretTrail")
    ],
    swiftLanguageVersions: [.v5]
)
