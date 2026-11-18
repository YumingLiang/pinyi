// swift-tools-version:6.0
// MosaicAccelerate — Apple 平台专用的 DistanceKernel 扩展点（技术方案 §7 / §11.1）。
// 在 Linux 上本包编译为空模块（所有实现都在 `#if canImport(Accelerate)` 内）。
import PackageDescription

/// G-1：Swift 6 语言模式（swiftLanguageModes）下数据竞争诊断即错误；另把所有警告当错误。
/// unsafeFlags 只允许用于本地 path 包——本项目三个包都只被本仓库以 path 依赖，零第三方依赖。
let strictSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

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
            path: "Sources/MosaicAccelerate",
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
