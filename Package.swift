// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperDrop2",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisperDrop", targets: ["WhisperDrop"]),
        .executable(name: "parakeet-server", targets: ["ParakeetServer"])
    ],
    dependencies: [
        // Pinned with the matching mlx.metallib in scripts/prepare-runtime.sh.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3")
    ],
    targets: [
        .target(name: "WhisperDropCore"),
        .executableTarget(name: "WhisperDrop", dependencies: ["WhisperDropCore"]),
        // Parakeet TDT graph from mlx-audio-swift (MIT), without its Hugging Face loader.
        .target(name: "ParakeetMLX", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift")
        ], exclude: ["LICENSE-mlx-audio-swift.txt"]),
        .executableTarget(name: "ParakeetServer", dependencies: ["ParakeetMLX", "WhisperDropCore"]),
        .testTarget(name: "WhisperDropCoreTests", dependencies: ["WhisperDropCore"]),
        .testTarget(name: "WhisperDropAppTests", dependencies: ["WhisperDrop"])
    ]
)
