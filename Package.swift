// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnerDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RunnerDash"),
        .executableTarget(name: "IconTool"),
    ],
    swiftLanguageModes: [.v5]
)
