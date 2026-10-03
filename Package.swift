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
        // Rubber Band Library v4.0.0 (GPL-2.0-or-later), vendored unmodified in Vendor/RubberBand.
        .target(
            name: "CRubberBand",
            path: "Vendor/RubberBand",
            sources: ["single/RubberBandSingle.cpp"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(name: "MADSETCore", dependencies: ["CRubberBand"]),
        .executableTarget(name: "MADSET", dependencies: ["MADSETCore"]),
        .executableTarget(name: "MADSETBench", dependencies: ["MADSETCore"]),
        .testTarget(name: "MADSETCoreTests", dependencies: ["MADSETCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
