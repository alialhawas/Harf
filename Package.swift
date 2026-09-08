// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Harf",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "DodomaCore",
            path: "Sources/DodomaCore",
            resources: [.copy("Resources")]
        ),
        // Everything the running app is made of. A library rather than part of
        // the executable so that the app-side state machines — the suggestion
        // interaction, the accessibility gate, the undo slot — can be driven
        // from a test target. An executable target cannot be imported.
        .target(
            name: "DodomaAppKit",
            dependencies: ["DodomaCore"],
            path: "Sources/DodomaAppKit"
        ),
        // Nothing but the entry point.
        .executableTarget(
            name: "Harf",
            dependencies: ["DodomaAppKit"],
            path: "Sources/DodomaApp"
        ),
        .testTarget(
            name: "DodomaCoreTests",
            dependencies: ["DodomaCore"],
            path: "Tests/DodomaCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DodomaAppTests",
            dependencies: ["DodomaAppKit"],
            path: "Tests/DodomaAppTests"
        )
    ]
)
