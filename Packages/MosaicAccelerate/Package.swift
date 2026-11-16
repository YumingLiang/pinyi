// swift-tools-version:6.0
// MosaicAccelerate — Apple 平台专用的 DistanceKernel 扩展点（技术方案 §7 / §11.1）。
// 在 Linux 上本包编译为空模块（所有实现都在 `#if canImport(Accelerate)` 内）。
import PackageDescription

let package = Package(
    name: "MosaicAccelerate",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MosaicAccelerate", targets: ["MosaicAccelerate"]),
    ],
    dependencies: [
        .package(path: "../MosaicCore"),
    ],
    targets: [
        .target(
            name: "MosaicAccelerate",
            dependencies: [.product(name: "MosaicCore", package: "MosaicCore")],
            path: "Sources/MosaicAccelerate"
        ),
    ],
    swiftLanguageModes: [.v6]
)
