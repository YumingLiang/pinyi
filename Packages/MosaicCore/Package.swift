// swift-tools-version:6.0
// MosaicCore — 照片马赛克的纯 Swift 核心（颜色空间、特征、匹配、约束分配）。
// 约束：零外部依赖；不 import 任何 Apple 专有框架；必须能在 Linux 上 `swift build` / `swift test`。
import PackageDescription

/// G-1：Swift 6 语言模式（swiftLanguageModes）下数据竞争诊断即错误；另把所有警告当错误。
/// unsafeFlags 只允许用于本地 path 包——本项目三个包都只被本仓库以 path 依赖，零第三方依赖。
let strictSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

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
            path: "Sources/MosaicCore",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MosaicCoreTests",
            dependencies: ["MosaicCore"],
            path: "Tests/MosaicCoreTests",
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
