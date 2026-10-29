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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.5.0"),
        .package(url: "https://github.com/xocialize/qwen-image-edit-swift.git", exact: "0.11.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
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
