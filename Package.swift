// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicLock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MicLock", targets: ["MicLock"])],
    targets: [
        .target(name: "MicLockCore"),
        .executableTarget(name: "MicLock", dependencies: ["MicLockCore"]),
        .testTarget(name: "MicLockCoreTests", dependencies: ["MicLockCore"]),
    ]
)
