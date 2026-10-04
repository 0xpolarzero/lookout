// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lookout",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Lookout", path: "Sources/Lookout"),
        .testTarget(name: "LookoutTests", dependencies: ["Lookout"], path: "Tests/LookoutTests"),
    ]
)
