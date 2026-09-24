// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeUsageBar", path: "Sources/ClaudeUsageBar"),
        .testTarget(name: "ClaudeUsageBarTests", dependencies: ["ClaudeUsageBar"], path: "Tests/ClaudeUsageBarTests"),
    ]
)
