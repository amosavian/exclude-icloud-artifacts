// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "exclude-icloud-artifacts",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.13.2"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "exclude-icloud-artifacts",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "exclude-icloud-artifactsTests",
            dependencies: [
                "exclude-icloud-artifacts",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
    ]
)
