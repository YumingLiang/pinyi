# CHANGES — feat/mosaic-core

日期：2026-11-16（PT）　作者：全栈开发　依据：技术方案 **v0.2**（取代 v0.1）、产品决定 v0.3、文案 v1.1、QA `qa/examples`

## 本分支做了什么

1. **MosaicCore**（`Packages/MosaicCore`，swift-tools-version 6.0，Swift 6 语言模式，平台 iOS 16 / macOS 13，零依赖，不 import 任何 Apple 专有框架）
   - `Color/`：sRGB ↔ 线性（含 256 项 LUT）、OKLab（Ottosson 矩阵，默认）、CIELAB(D65)（仅保留转换 + 对照表用例）。
   - `Features/`：`PixelBuffer`（RGBA8/BGRA8、行填充）、`FeatureVector`（2×2 子块 × L/a/b = 12 维，`SIMD16` 存储）、`FeatureRecord`（+ 亮度方差、宽高比、flags）、`FeatureExtractor`（默认中心正方形裁剪、线性光平均）、`FeatureMatrix`（SoA 12×N）。
   - `Matching/`：`DistanceKernel` 协议（签名同方案 §11.1）、`ScalarSIMDKernel`（分块 + 多核、平方欧氏、(距离, 下标) 排序）、`TopKResult`、`BitMask`（并集/交集/多来源去重）、`SplitMix64` / `Xoshiro256StarStar`（自带 Lemire 有界随机与 Fisher–Yates，不用标准库随机算法）、`GreedyAssigner`（带惩罚随机顺序贪心 + 回退链）、`MaterialSupply`（200 张阈值）、`MosaicSeed`（换一种拼法的种子派生）。
   - `Layout/`：`Layout.grid(width:height:density:) -> GridLayout`（§3.6：正方形格、长边 N 格、短边向下取整、余量居中裁掉、导出尺寸）、`MosaicGrid`、`Neighborhood`、`TargetSampler`、`MosaicPipeline`（`generate` / `reshuffle`）。
2. **MosaicAccelerate**（`Packages/MosaicAccelerate`）：`#if canImport(Accelerate)` 守卫的 `AccelerateKernel` 扩展点，**目前委托给 ScalarSIMDKernel**（占位）；Metal 不做，只留注释。
3. **App 骨架**：`App/PhotoMosaicApp.swift`（SwiftUI 占位页，按 key 取文案，`KernelProvider` 注入内核）、`App/PrivacyInfo.xcprivacy`、`AppTests/`。
4. **文案**：`App/Resources/copy_v1.1.md`（原样复制）→ `scripts/gen-localizable.py` 生成 `zh-Hans.lproj/Localizable.strings`（138 个 key）与 `InfoPlist.strings`（2 个权限文案 + CFBundleDisplayName）；占位符 `{name}` → `%1$@`…；`--check` 模式进 CI。
5. **XcodeGen `project.yml`**、**CI 草稿** `.github/workflows/linux-core.yml` 与 `ios.yml`、`scripts/check-no-network.sh`（零网络 / 零远程依赖守护）。

## 关键设计决定

- **邻域**：`Neighborhood.moore(radius:)`（切比雪夫距离）/ `.vonNeumann(radius:)`（曼哈顿距离）。默认主邻域 = 8 邻域（半径 1，**所有档位**，含 120 档）；放宽邻域 = 4 邻域。每格只与**已分配**的邻居比较，邻域对称 ⇒ 未放宽的格子之间任意两格在 8 邻域内都不重复（测试对全图逐对验证）。
- **回退链**（每格逐级，记录在 `levels`）：
  0 `primary` top‑32 → 1 `expandedCandidates` 重算 top‑128 → 2 `exhaustiveSearch` 全库搜索（**补充项**，见偏差 1）→ 3 `relaxedNeighborhood` 只禁 4 邻域 → 4 `capIgnored` 忽略上限 → 5 `neighborhoodIgnored` 兜底（只剩 1–2 张素材时）。
  `relaxedConstraints = relaxationCount > 0`，`relaxationCount` = 3/4/5 级格子数（**不含**只扩 k / 全库搜索）。
- **打分**：`score = dist + λ·uses`，`uses ≥ cap` 排除；平局 (score, dist, index) 升序。λ 默认 0.005（OKLab 12 维平方距离尺度，待合成 A/B 调参）。
- **上限**：`cap = max(1, ceil(格子数 / 可用数 × 2))`，可用数取掩码后张数；不开放给用户（`UsageCap.limited/unlimited` 只供测试/内部）。
- **可复现**：遍历顺序 = `Xoshiro256**(seed)` 的 Fisher–Yates 排列；内核结果与线程数/分块无关（测试覆盖）；同种子 + 同素材快照 + 同参数 ⇒ 逐格一致。「换一种拼法」= `MosaicPipeline.reshuffle`，种子 = `MosaicSeed.next(after:)`（SplitMix64 一步，可指定）。
- **子块均值**：默认在**线性光**中求均值再转 OKLab（物理上等于远看的混色，每块只做 1 次转换）；`.perceptual`（逐像素转 OKLab 再平均）可选。
- **网格**：M = `max(1, 短边×N ÷ 长边)` 用**整数**运算（浮点 `3 ÷ 0.05 = 59.999…` 会少算一行，有专门测试）。

## 测试结果（Linux，box：Debian 13 x86_64，8 核，Swift 6.2.4 官方 toolchain）

- `swift test`（debug，含干净构建）：**81 个测试，0 失败**；测试执行 8.0 s，含构建总计 15.9 s。完整输出：`reports/swift-test-linux.txt`。
  套件：Assignment 19、Color 8、ConstrainedMatching 7（QA 移植）、Feature 11、Layout 10、Matching 11、Performance 3、Random 6、SupplyAndReshuffle 6。
- 全规模基准（release，`reports/swift-bench-linux-release.txt`）：top‑32，10,800 格 × 5 万素材 **0.20 s**；完整分配 0.21 s；**最坏情况**（整张目标图同一颜色、cap = 1）**3.3 s**，其中 10,672 格走全库搜索。
- `MosaicAccelerate` 在 Linux 上 `swift build` 通过（空模块）。
- `xcodegen generate`：在 Linux 上用自编译的 XcodeGen 2.46.0 成功生成 `.xcodeproj`（输出到 /tmp，不入库）；scheme 含 PhotoMosaicTests + `MosaicCoreTests`；`.strings` 进 Resources，`copy_v1.1.md` 不打包。**但没有 Xcode，未做 xcodebuild 编译 / 模拟器测试**。

## 与方案的偏差 / 待架构师确认

1. **回退链增加“全库搜索”一级**（`exhaustiveSearchBeforeRelaxing`，默认开）。原因：目标图有大片相近颜色时，相邻格的 128 近邻高度重叠，上限很快用尽；按原链会在素材充足时（测试：1,500 张、1,200 格、cap 2）有 262 格“忽略上限”，并误报 `relaxedConstraints`。代价：最坏情况（纯色目标图）在 box 上 3.3 s，iPhone 11 可能更慢，**会挤占“中档 ≤ 10 秒”**。可选方案：(a) 保留并在真机测；(b) 改成分批预算更深的 top‑k（内存换时间）；(c) 关掉，接受误报。请定。
2. **极端长图短边不足一格**（例如 3000×50、40 档，s = 75 > 50）：方案的“正方形 + 不补边 + M ≥ 1”互相矛盾。现在是**不裁不补**，唯一一行格子取 s × 短边 的长方形区域，并置 `shortEdgeUnderflow = true`；导出尺寸仍按 M × 格边长，会改变宽高比。请定处理方式（例如限制最小短边或补边）。
3. **导出尺寸**：格边 = ⌊导出长边 ÷ N⌋，长边不整除时导出图略小（如 4000 ÷ 120 → 33 px，长边 3960），不拉伸。请确认可接受。
4. **子块均值用线性光**（方案写“子块 OKLab 均值”，未说明在哪个空间平均）。
5. **λ = 0.005** 是暂定值；方案未给数。
6. **CI 文件名**：派单写 `ios-ci.yml`（一个文件两个 job），按方案 §11.3 拆成 `linux-core.yml` + `ios.yml`（便于 paths 过滤：纯 MosaicCore 改动不触发 macOS）；TestFlight 只在 `ios.yml` 末尾留注释占位，没建 `testflight.yml`。
7. 方案 §7/§2.3 的 `features.bin` 二进制格式读写、条带切分、叠加混合数学**本分支未做**（属 D3 / 后续卡片）。
8. 方案 §5.1 的生成取消（内核检查 `Task.isCancelled`）**未做**；`GreedyAssigner` 目前是同步、不可取消的。
9. 方案 §2.1 的亮度方差“惩罚纯色图过度使用”只算了方差并打 `lowDetail` 标志，**未进打分**。
10. Swift 版本：box 与 CI 容器用 6.2（Xcode 26 自带）。XcodeGen 更新日志提到 Xcode 27.2，**当前 runner 镜像的 Xcode 版本未核实**。

## QA 骨架对齐（`qa/examples/ConstrainedMatchingTests.swift`）

已移植为可编译测试 `Packages/MosaicCore/Tests/MosaicCoreTests/ConstrainedMatchingTests.swift`（7 个用例全过），按骨架注释实现了 `SyntheticFixture`。**`qa/` 下原文件未改动**，QA 可决定是否删除或指向新文件。对照：

| QA 骨架 | MosaicCore 实际 |
|---|---|
| `ConstrainedMatcher.assign(fixture:constraints:)` | `GreedyAssigner(configuration:kernel:).assign(grid:cellFeatures:library:mask:)` |
| `MatchingConstraints` / `.schemeDefault(cellCount:availableCount:seed:)` | `AssignmentConfiguration(seed:)`（cap 默认按公式自动算，无需传格子数/可用数） |
| `MatchingConstraints.defaultCap(cellCount:availableCount:)` | 同名 `AssignmentConfiguration.defaultCap(...)`（为对齐新增）；底层 `UsageCap.default.resolve` |
| `constraints.cap = 2`（Int） | `cap: .limited(2)`（另有 `.automatic(multiplier:)` / `.unlimited`） |
| `kFallback` / `neighborhoodRadius` / `lambda` | `fallbackK` / `neighborhood: .moore(radius:)` / `usagePenalty` |
| `constraints.mask` | `assign(..., mask:)` 参数 |
| `Assignment.indices: [UInt32]` | `MosaicAssignment.tiles: [Int]` |
| `materialShortageCount` | `statistics.relaxationCount` / `relaxedConstraints`（另有 `needsRepetition`、`isBelowMaterialThreshold`） |
| `BitMask(count:filled:)` / `mask.set(i, false)` | `BitMask(count:allSet:)` / `mask[i] = false` |
| `SplitMix64(seed:).next()` | 相同 |
| `ScalarSIMDKernel().topK(queries:m:candidates:n:dims:k:mask:)` | 相同（另有 `FeatureMatrix` 封装） |
| 存储布局注释写“12×N 行主序” | 实际为 **SoA（维度优先）`storage[d * n + i]`**，与方案 §11.1 “SoA 12×N”一致 |
| 骨架中“换种子结果不同”为弱断言 | 移植后改为强断言（夹具是确定的，已验证不同） |
| 回退链 k32 → k128 → 4 邻域 → 忽略上限 | 多了“全库搜索”与“忽略邻域”两级（见偏差 1） |

## 红线确认

未创建远程仓库、未 push、未花钱；无任何联网 API / 第三方依赖（`check-no-network.sh` 通过）。只装了 swift.org 官方 Swift 6.2.4（签名校验通过）、Debian 官方 libncurses6，以及在 /tmp 编译的 XcodeGen（仅本地验证，不入库）。
