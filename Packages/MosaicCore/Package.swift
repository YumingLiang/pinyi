// swift-tools-version:6.0
// MosaicCore — 照片马赛克的纯 Swift 核心（颜色空间、特征、匹配、约束分配）。
// 约束：零外部依赖；不 import 任何 Apple 专有框架；必须能在 Linux 上 `swift build` / `swift test`。
import PackageDescription

let package = Package(
    name: "MosaicCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MosaicCore", targets: ["MosaicCore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MosaicCore",
            path: "Sources/MosaicCore"
        ),
        .testTarget(
            name: "MosaicCoreTests",
            dependencies: ["MosaicCore"],
            path: "Tests/MosaicCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
