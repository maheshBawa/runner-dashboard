// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnerDashboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "RunnerDash",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // build.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "IconTool"),
    ],
    swiftLanguageModes: [.v5]
)
