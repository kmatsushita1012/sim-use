// swift-tools-version: 5.10
import PackageDescription

// SimUseKit re-exports the iOS simulator backend. Its static idb
// XCFrameworks refer to these private-framework Clang modules, so an
// application importing the public facade needs the same module maps
// while compiling its own target.
let simUseRoot = "\(Context.packageDirectory)/../.."
let privateHeadersDir = "\(simUseRoot)/build_products/PrivateHeaders"
let privateModuleMapFlags: [String] = ["-Xcc", "-I\(privateHeadersDir)"] + [
    "CoreSimulator", "SimulatorApp", "SimulatorKit", "AXRuntime",
    "AccessibilityPlatformTranslation",
].flatMap {
    ["-Xcc", "-fmodule-map-file=\(privateHeadersDir)/\($0)/module.modulemap"]
}

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
            ],
            swiftSettings: [
                .unsafeFlags(privateModuleMapFlags)
            ]
        )
    ]
)
