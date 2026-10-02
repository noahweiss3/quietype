// swift-tools-version:6.0
import PackageDescription

// MurmurCore and murmur-cli are portable (they build and test on Linux).
// Everything that touches AppKit, CoreML or Metal is macOS-only and is added below.

var products: [Product] = [
    .library(name: "MurmurCore", targets: ["MurmurCore"]),
    .executable(name: "murmur-cli", targets: ["murmur-cli"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "MurmurCore"),
    .executableTarget(name: "murmur-cli", dependencies: ["MurmurCore"]),
    .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
]

#if os(macOS)
dependencies.append(
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")
)

products += [
    .executable(name: "Murmur", targets: ["Murmur"]),
    .executable(name: "murmur-bench", targets: ["murmur-bench"]),
]

targets += [
    // llama.cpp, pinned to a release so its C API doesn't shift under us.
    .binaryTarget(
        name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b11351/llama-b11351-xcframework.zip",
        checksum: "f2ce4a7923eca2ed8d0eaf6577429f2446ba6fd7a66b0efe02ea414a04fff3be"
    ),
    .target(
        name: "MurmurKit",
        dependencies: [
            "MurmurCore",
            "llama",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]
    ),
    .executableTarget(name: "Murmur", dependencies: ["MurmurCore", "MurmurKit"]),
    .executableTarget(name: "murmur-bench", dependencies: ["MurmurCore", "MurmurKit"]),
    .testTarget(name: "MurmurKitTests", dependencies: ["MurmurKit"]),
]
#endif

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
