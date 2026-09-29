// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperDrop2",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WhisperDrop", targets: ["WhisperDrop"])],
    targets: [
        .target(name: "WhisperDropCore"),
        .executableTarget(name: "WhisperDrop", dependencies: ["WhisperDropCore"]),
        .testTarget(name: "WhisperDropCoreTests", dependencies: ["WhisperDropCore"])
    ]
)
