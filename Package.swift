// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ai-reviewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ai-reviewer-watcher", targets: ["AIReviewerWatcher"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AIReviewerWatcher",
            path: "Sources/AIReviewerWatcher"
        )
    ]
)
