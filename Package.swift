// swift-tools-version:6.0
import PackageDescription

// QuietypeCore and quietype-cli are portable (they build and test on Linux).
// Everything that touches AppKit, CoreML or Metal is macOS-only and is added below.

var products: [Product] = [
    .library(name: "QuietypeCore", targets: ["QuietypeCore"]),
    .executable(name: "quietype-cli", targets: ["quietype-cli"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "QuietypeCore"),
    .executableTarget(name: "quietype-cli", dependencies: ["QuietypeCore"]),
    .testTarget(name: "QuietypeCoreTests", dependencies: ["QuietypeCore"]),
]

#if os(macOS)
dependencies.append(
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")
)

products += [
    .executable(name: "Quietype", targets: ["Quietype"]),
    .executable(name: "quietype-bench", targets: ["quietype-bench"]),
]

targets += [
    // llama.cpp, pinned to a release so its C API doesn't shift under us.
    .binaryTarget(
        name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b11351/llama-b11351-xcframework.zip",
        checksum: "f2ce4a7923eca2ed8d0eaf6577429f2446ba6fd7a66b0efe02ea414a04fff3be"
    ),
    .target(
        name: "QuietypeKit",
        dependencies: [
            "QuietypeCore",
            "llama",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]
    ),
    .executableTarget(name: "Quietype", dependencies: ["QuietypeCore", "QuietypeKit"]),
    .executableTarget(name: "quietype-bench", dependencies: ["QuietypeCore", "QuietypeKit"]),
    .testTarget(name: "QuietypeKitTests", dependencies: ["QuietypeKit"]),
]
#endif

let package = Package(
    name: "Quietype",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
