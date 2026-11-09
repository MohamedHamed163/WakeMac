// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WakeMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WakeKit", targets: ["WakeKit"]),
        .executable(name: "WakeMacApp", targets: ["WakeMacApp"]),
    ],
    targets: [
        .target(
            name: "WakeKit",
            path: "Sources/WakeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WakeMacApp",
            dependencies: ["WakeKit"],
            path: "Sources/WakeMacApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WakeKitTests",
            dependencies: ["WakeKit"],
            path: "Tests/WakeKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
