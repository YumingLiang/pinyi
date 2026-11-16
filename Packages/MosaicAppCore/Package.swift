// swift-tools-version:6.0
// MosaicAppCore — App 层的纯 Swift 逻辑（状态机、ViewModel 逻辑、增量 diff、权限映射、计时统计）。
// 约束：只依赖 MosaicCore；不 import SwiftUI / UIKit / Photos / Combine；必须能在 Linux 上 `swift test`。
// 相册、权限、缩略图来源都用协议抽象（`PhotoLibraryProviding` / `ThumbnailProviding`），
// App target 里放 PhotoKit 适配器，测试里放 fake。
import PackageDescription

/// G-1：Swift 6 语言模式（swiftLanguageModes）下数据竞争诊断即错误；另把所有警告当错误。
/// unsafeFlags 只允许用于本地 path 包——本项目三个包都只被本仓库以 path 依赖，零第三方依赖。
let strictSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

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
            path: "Sources/MosaicAppCore",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MosaicAppCoreTests",
            dependencies: ["MosaicAppCore", .product(name: "MosaicCore", package: "MosaicCore")],
            path: "Tests/MosaicAppCoreTests",
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
