// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Blendline",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Blendline", targets: ["Blendline"]),
        .executable(name: "blendline-bench", targets: ["BlendlineBench"]),
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
        .target(name: "BlendlineCore", dependencies: ["CRubberBand"]),
        .executableTarget(name: "Blendline", dependencies: ["BlendlineCore"]),
        .executableTarget(name: "BlendlineBench", dependencies: ["BlendlineCore"]),
        .testTarget(name: "BlendlineCoreTests", dependencies: ["BlendlineCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
