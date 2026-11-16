# 拼忆（照片马赛克）iOS App

iOS 16+，Swift 6 + SwiftUI，零网络。架构以 `tech-design-v0.2.md` 为准（架构师维护）；产品决定 `product/decisions-v0.3.md`；QA 用例 `qa/`。这三处由各自负责人维护，**未纳入本仓库版本控制**。改动说明见 `CHANGES.md`。

## 目录

```
photomosaic/
├─ Packages/
│  ├─ MosaicCore/          # 纯 Swift：颜色空间、特征、features.bin、top-k、约束贪心、网格/条带/叠加。Linux 可 build + test
│  ├─ MosaicAppCore/       # 纯 Swift：App 层状态机 / 增量索引（PhotoIndex）/ 权限映射 / 计时统计；协议抽象相册，fake 驱动测试。Linux 可 test
│  └─ MosaicAccelerate/    # Apple 专属 DistanceKernel 扩展点（#if canImport(Accelerate)），Linux 上为空模块
├─ App/                    # SwiftUI 视图（Views/）+ PhotoKit/UIKit 适配器（Adapters/）+ AppModel；逻辑全在 MosaicAppCore
│  └─ Resources/           # copy_v1.1.md（文案源，带 key）+ zh-Hans.lproj/{Localizable,InfoPlist}.strings（生成）
├─ AppTests/               # iOS 模拟器单元测试
├─ project.yml             # XcodeGen（.xcodeproj 不入库）
├─ scripts/check-no-network.sh   # 零网络 / 零第三方依赖守护
├─ scripts/gen-localizable.py    # 文案表 → .strings（--check 用于 CI）
├─ .github/workflows/      # linux-core.yml（Linux swift test + 全规模基准 job）、ios.yml（macOS 模拟器）
└─ reports/                # 测试输出存档
```

## MosaicCore 用法

```swift
import MosaicCore

// 1. 素材特征（iOS 侧把 32×32 缩略图解码成 PixelBuffer；若是 Display P3 字节，标 colorSpace: .displayP3）
let extractor = FeatureExtractor()                        // OKLab, 2×2 子块, 线性光平均（口径见 FeatureSpec）
let record = try extractor.extract(from: thumbnailPixels) // 默认中心正方形裁剪；同时算亮度方差
var table = FeatureTable(records: allRecords)             // SoA 12×N + 方差 + flags + 口径
try FeatureFile.write(table, to: featuresURL)             // features.bin：分块 CRC、原子写入
let read = try FeatureFile.read(from: featuresURL)        // mmap；截断/坏块 → 保留有效前缀，read.rowsToRebuild 重算
table.markDeleted(row); try FeatureFile.compactIfNeeded(at: featuresURL) // tombstone；空洞率 > 20% 压缩重写

// 2. 快照：来源（MVP UI 单选；引擎支持多相簿并集）∧ 已扫描 ∧ 未删除
let snapshot = try LibrarySnapshot(table: table, rowLimit: scannedRows, sourceMask: albumMask)
switch snapshot.supply {
case .empty: break                  // 空状态，不进生成
case .insufficient: break           // < 200 张：生成前提示一次，不阻止
case .sufficient: break
}

// 3. 生成（可取消：Task.cancel() 或 CancellationToken；取消抛 CancellationError，不产出半成品）
let pipeline = MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make()))
let gen = try await pipeline.generate(target: targetPixels, density: .medium, table: table, seed: seed) { p in
    progress = p.overallFraction                  // 可选进度（任意线程）
}
gen.layout.cropRect / gen.layout.cellRect(i)      // 网格：正方形格；短边向下取整居中裁；极端长图（> N:1）方案 A
gen.layout.exportSize(longEdge: 4000)             // 每格 = floor(4000 ÷ N)，不做最后缩放（细档 3960）
gen.layout.exportStrips(longEdge: 4000)           // 导出条带（≤ 512 px、整行对齐）
gen.assignment.tiles                              // 行优先，每格的素材下标
gen.shouldShowShortageNotice                      // 结果页 `shortage.result`：仅当可用 < 200 且实际放宽了约束
gen.assignment.statistics.neighborhoodRelaxedCount / .capIgnoredCount   // 两项放宽计数（诊断用）
OverlayBlend.blend(tile: px, target: tgt, alpha: 0.15)                 // 原图叠加 (1−α)·块 + α·原图，α ∈ [0, 0.3]

// 4. 换一种拼法：只换种子，参数不变；同种子逐格可复现（取消后重跑同样一致）
let next = try pipeline.reshuffle(gen, target: targetPixels, table: table)
```

## 测试方法

Linux：CI 钉 `swift:6.3.3-noble`，与 `macos-26` runner 默认的 Xcode 26.6（Swift 6.3.3）一致。box 上装的是 `~/.local/swift-6.3.3/usr/bin`（另有 6.2.4）。Linux 耗时只防回归，**不能**作为 iPhone 11 性能证据，需真机验证：

```bash
cd Packages/MosaicCore
swift build
swift test                                   # 全部单元测试
MOSAIC_BENCH=1 swift test -c release --filter PerformanceTests   # A-21 全规模基准（CI 单独 job，只记录不阻断；加 MOSAIC_BENCH_ASSERT=1 才断言软阈值）
cd ../MosaicAppCore && swift test            # App 层逻辑（fake 相册 / 缩略图）
MOSAIC_BENCH=1 swift test -c release --filter IndexBenchTests  # 索引簿记开销（只打印；不是真机证据）
cd ../MosaicAccelerate && swift build        # Linux 上为空模块，只验证可编译
cd ../.. && ./scripts/check-no-network.sh    # 零网络守护
python3 scripts/gen-localizable.py --check   # .strings 与文案表一致
```

macOS（未验证，需 Xcode 26 + `brew install xcodegen`）：

```bash
xcodegen generate
xcodebuild test -project PhotoMosaic.xcodeproj -scheme PhotoMosaic \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

## 红线

- 零网络：不引入任何联网 API / SDK；`scripts/check-no-network.sh` 在 CI 中强制检查。
- 零第三方依赖：`Package.swift` 与 `project.yml` 只允许本地 path 包。
- 不入库任何签名材料（`.p8/.p12/.mobileprovision`），只放 GitHub Secrets。
