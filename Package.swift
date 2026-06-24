// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pii-stream",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PIIStream", targets: ["pii-stream"]),
        .executable(name: "pii-stream", targets: ["pii-stream-cli"]),
    ],
    targets: [
        .target(
            name: "pii-stream",
            path: "Sources/pii-stream"
        ),
        .executableTarget(
            name: "pii-stream-cli",
            dependencies: ["pii-stream"],
            path: "Sources/pii-stream-cli"
        ),
        .executableTarget(
            name: "pii-stream-checks",
            dependencies: ["pii-stream"],
            path: "Tests/pii-streamChecks"
        ),
    ]
)
