// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-qwen-image: Qwen-Image-Edit 2511 and Qwen-Image Flash as a Gaea plugin. One worker executable built on
// GaeaPluginKit over qwen-image-edit-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// qwen-inproc is not part of the plugin: it runs the same packages in-process through MLXServeEngine, with the same
// dependency resolution, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-qwen-image",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"), // 0.14.1 on: the manifest names the engine actually linked (AB-L-0366)
        .package(url: "https://github.com/xocialize/qwen-image-edit-swift.git", exact: "0.12.0"), // its newest (0.12.0 changes only the Turbo package, which this plugin does not link); admits mlx-swift 0.33.x (ml-explore from 0.32.3)
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.82.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). Named
        // at the root so no dependency's ml-explore URL wins and builds the unpatched one.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.33.1"),
    ],
    targets: [
        .target(
            name: "QwenPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "QwenImageEdit", package: "qwen-image-edit-swift"),
                .product(name: "MLXQwenImageEdit", package: "qwen-image-edit-swift"),
                .product(name: "MLXQwenImageFlash", package: "qwen-image-edit-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ],
            // v0.9.1's Qwen-Image adapter registry, verbatim (mlx-image-runtime 0.15.0 = qwen-image-edit-swift
            // registry/qwen-image.json @16584ad), compiled into the worker: the bundle carries no SwiftPM resource bundle.
            resources: [.embedInCode("Resources/qwen-image.json")]
        ),
        .executableTarget(
            name: "gaea-qwen-image-worker",
            dependencies: [
                "QwenPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "qwen-inproc",
            dependencies: [
                "QwenPlugin",
                .product(name: "MLXQwenImageEdit", package: "qwen-image-edit-swift"),
                .product(name: "MLXQwenImageFlash", package: "qwen-image-edit-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
