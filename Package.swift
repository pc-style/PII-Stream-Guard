// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pii-stream",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pii-stream", targets: ["pii-stream"]),
    ],
    targets: [
        .executableTarget(
            name: "pii-stream",
            path: "Sources/pii-stream"
        ),
    ]
)
