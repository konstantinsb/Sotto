// swift-tools-version:6.0
import PackageDescription

// Ядро приложения и движки.
// - SottoCore: домен, протоколы, фейки, оркестратор, реестр моделей — чистый Swift.
// - SottoWhisper: TranscriptionEngine на WhisperKit (Core ML + ANE).
// - SottoMLX: LLMEngine на MLX (Metal, unified memory). ВНИМАНИЕ: компилируется
//   только через Xcode (Metal-шейдеры), `swift build` этот таргет не соберёт.
let package = Package(
    name: "SottoCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SottoCore", targets: ["SottoCore"]),
        .library(name: "SottoWhisper", targets: ["SottoWhisper"]),
        .library(name: "SottoParakeet", targets: ["SottoParakeet"]),
        .library(name: "SottoMLX", targets: ["SottoMLX"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "SottoCore"
        ),
        .target(
            name: "SottoWhisper",
            dependencies: [
                "SottoCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .target(
            name: "SottoParakeet",
            dependencies: [
                "SottoCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .target(
            name: "SottoMLX",
            dependencies: [
                "SottoCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .testTarget(
            name: "SottoCoreTests",
            dependencies: ["SottoCore"]
        )
    ]
)
