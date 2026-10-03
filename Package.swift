// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MADSET",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MADSET", targets: ["MADSET"]),
        .executable(name: "madset-bench", targets: ["MADSETBench"]),
    ],
    targets: [
        .target(name: "MADSETCore"),
        .executableTarget(name: "MADSET", dependencies: ["MADSETCore"]),
        .executableTarget(name: "MADSETBench", dependencies: ["MADSETCore"]),
        .testTarget(name: "MADSETCoreTests", dependencies: ["MADSETCore"]),
    ]
)
