// swift-tools-version:6.0
// MosaicAppCore — App 层的纯 Swift 逻辑（状态机、ViewModel 逻辑、增量 diff、权限映射、计时统计）。
// 约束：只依赖 MosaicCore；不 import SwiftUI / UIKit / Photos / Combine；必须能在 Linux 上 `swift test`。
// 相册、权限、缩略图来源都用协议抽象（`PhotoLibraryProviding` / `ThumbnailProviding`），
// App target 里放 PhotoKit 适配器，测试里放 fake。
import PackageDescription

let package = Package(
    name: "MosaicAppCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MosaicAppCore", targets: ["MosaicAppCore"]),
    ],
    dependencies: [
        .package(path: "../MosaicCore"),
    ],
    targets: [
        .target(
            name: "MosaicAppCore",
            dependencies: [.product(name: "MosaicCore", package: "MosaicCore")],
            path: "Sources/MosaicAppCore"
        ),
        .testTarget(
            name: "MosaicAppCoreTests",
            dependencies: ["MosaicAppCore", .product(name: "MosaicCore", package: "MosaicCore")],
            path: "Tests/MosaicAppCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
