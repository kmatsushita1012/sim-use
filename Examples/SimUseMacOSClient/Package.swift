// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SimUseMacOSClient",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "SimUseMacOSClient",
            dependencies: [
                .product(name: "SimUseKit", package: "sim-use")
            ]
        )
    ]
)
