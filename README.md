# 拼忆（照片马赛克）iOS App

iOS 16+，Swift 6 + SwiftUI，零网络。架构以 `tech-design-v0.2.md` 为准（架构师维护）；产品决定 `product/decisions-v0.3.md`；QA 用例 `qa/`。这三处由各自负责人维护，**未纳入本仓库版本控制**。改动说明见 `CHANGES.md`。

## 目录

```
photomosaic/
├─ Packages/
│  ├─ MosaicCore/          # 纯 Swift：颜色空间、特征、top-k、约束贪心。Linux 可 build + test
│  └─ MosaicAccelerate/    # Apple 专属 DistanceKernel 扩展点（#if canImport(Accelerate)），Linux 上为空模块
├─ App/                    # SwiftUI 外壳（T1 骨架占位）+ PrivacyInfo.xcprivacy
│  └─ Resources/           # copy_v1.1.md（文案源，带 key）+ zh-Hans.lproj/{Localizable,InfoPlist}.strings（生成）
├─ AppTests/               # iOS 模拟器单元测试
├─ project.yml             # XcodeGen（.xcodeproj 不入库）
├─ scripts/check-no-network.sh   # 零网络 / 零第三方依赖守护
├─ scripts/gen-localizable.py    # 文案表 → .strings（--check 用于 CI）
├─ .github/workflows/      # linux-core.yml（Linux swift test）、ios.yml（macOS 模拟器）
└─ reports/                # 测试输出存档
```

## MosaicCore 用法

```swift
import MosaicCore

// 1. 素材特征（iOS 侧把 32×32 缩略图解码成 PixelBuffer）
let extractor = FeatureExtractor()                        // OKLab, 2×2 子块, 线性光平均
let record = try extractor.extract(from: thumbnailPixels) // 默认中心正方形裁剪
let library = FeatureMatrix(records: allRecords)          // SoA 12×N

// 2. 来源：MVP UI 单选；引擎支持多相簿并集（重复照片自动去重）
let mask = try BitMask(count: library.count, sources: [albumRows])
switch MaterialSupply.evaluate(library: library, mask: mask) {
case .empty: break                  // 空状态，不进生成
case .insufficient: break           // < 200 张：生成前提示一次，不阻止
case .sufficient: break
}

// 3. 生成（网格：长边 N 格、短边向下取整、余量居中裁掉）
let pipeline = MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make()))
let gen = try pipeline.generate(target: targetPixels, density: .medium,
                                library: library, mask: mask, seed: seed)
gen.layout.cropRect / gen.layout.cellRect(i) / gen.layout.exportSize(longEdge: 4000)
gen.assignment.tiles                              // 行优先，每格的素材下标
gen.assignment.statistics.relaxedConstraints      // → 结果页短版「有些照片重复用了几次」

// 4. 换一种拼法：只换种子，参数不变；同种子逐格可复现
let next = try pipeline.reshuffle(gen, target: targetPixels, library: library, mask: mask)
```

## 测试方法

Linux（box 上已装 Swift 6.2.4，路径 `~/.local/swift-6.2.4/usr/bin`；与 Xcode 26 自带的 Swift 6.2 对齐）：

```bash
cd Packages/MosaicCore
swift build
swift test                                   # 全部单元测试
MOSAIC_BENCH=1 swift test -c release --filter PerformanceTests   # 方案全规模基准：10,800 格 × 5 万素材
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
