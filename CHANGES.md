# CHANGES

## feat/mosaic-core-io-cancel（基于 a0102be）

日期：2026-11-16（PT）　依据：技术方案 v0.2、产品决定 v0.3（含 01:10 / 01:12 补充）、架构师评审 `reviews/mosaic-core-a0102be.md`、QA `qa/a-layer-coverage.md`、文案 copy_v1.1（已再次同步）。

### 1. features.bin（格式 v1）— `Sources/MosaicCore/Storage/`

全部小端。`FeatureFile.write/read/decode/readHeader/compactIfNeeded`，`FeatureTable`（SoA 矩阵 + 方差 + 宽高比 + flags + `FeatureSpec`），`CRC32`（自实现 IEEE，"123456789" → 0xCBF43926）。

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 8 | magic `"PMFEAT\0\0"` |
| 8 | 2 | 容器格式版本 = 1 |
| 10 | 2 | 头部长度 = 64 |
| 12 | 4 | 特征版本（`MosaicCoreInfo.featureVersion`，本分支 **1 → 2**：cbrt 换成跨平台实现 + 单遍方差） |
| 16 | 4 | 维度 = 12 |
| 20 | 4 | 记录数（含 tombstone） |
| 24 | 4 | 每块记录数（默认 4096） |
| 28 | 1 | 颜色空间（0 OKLab / 1 CIELAB） |
| 29 | 1 | 平均方式（0 线性光 / 1 感知）——评审 S4 的口径写进头部 |
| 30 | 2 | 保留 |
| 32 | 4 | tombstone 数（冗余，不读正文就能判断是否要压缩） |
| 36 | 20 | 保留 |
| 56 | 4 | 头部 CRC32（覆盖 0..<56） |
| 60 | 4 | 保留 |
| 64… | | 若干块；每块 r 条记录，块内 SoA：12×r Float32 → r×方差 → r×宽高比 → r×flags(UInt32) → 块 CRC32 |

每条记录 60 B，5 万条 2.86 MB。

- **读取**：`Data(contentsOf:options:.alwaysMapped)`（mmap，Linux/Darwin 同一代码），校验后块内 SoA 一次拷贝成全局 SoA `FeatureMatrix`（5 万条 release 7 ms）。没有直接在映射内存上匹配：拷贝只有约 3 MB，换来 `FeatureMatrix` 保持值语义、mmap 生命周期不外泄。
- **写入**：同目录临时文件 `O_EXCL` → `write` → `fsync` → `rename(2)` → 尽力 fsync 目录；失败时删除临时文件，旧文件不受影响（libc 用 `#if canImport(Glibc/Musl/Darwin)` 守卫）。
- **错误与恢复**（`FeatureFileError.recommendedRecovery`）：
  - 丢弃重建（§2.5 全量 diff，特征可由 64px 图集重算）：文件不存在、太短、magic 错、头部 CRC 错、容器版本不支持、**特征版本不匹配**、维度/口径不符、I/O。
  - 保留可用前缀：截断、某块 CRC 错、尾部多余字节。`read(recovery: .keepValidPrefix)`（默认）返回前缀与 `rowsToRebuild`（行号不变，只重算之后的行）；`.discardAndRebuild` = 严格模式，任何损坏都抛错。
  - 分块就是为了"保留前缀"可行：纯 SoA 整文件一处损坏就全废。
- **tombstone / 压缩**（A-09）：`markDeleted` 打 `FeatureFlags.deleted`，`liveMask` 排除；空洞率 **> 20%**（等于 20% 不触发）时 `compacted()` / `FeatureFile.compactIfNeeded(at:)` 原子重写并返回 `oldToNew` 行号映射给 `index.sqlite`。

### 2. 可取消生成（评审 M2）— `Matching/Cancellation.swift`

- `CancellationToken`（锁保护，任意线程 `cancel()`）+ 同步入口同时检查当前线程的 `Task.isCancelled`；`async` 入口（`MosaicPipeline.generate(...) async`）用 `withTaskCancellationHandler` 把 Task 取消转成令牌。内核工作线程不在 Task 上下文里，所以必须有令牌。
- 检查点：内核每个查询组（16 查询 × 全库）、分配主循环每 64 格（`cancellationCheckInterval`）、每次逐格扩 k / 批量加深 / 全库搜索之前。
- 取消抛 Swift 标准的 `CancellationError`（评审建议 `MosaicError.cancelled`；用标准类型是为了和 `Task` 生态一致，`try await` 调用方不需要区分两种取消）。**不返回任何部分结果**；取消不动随机序列，重跑同种子逐格一致（测试覆盖）。
- 实测取消延迟（release）：跨线程 0.9 ms、`Task.cancel` 0.6 ms、全规模匹配中途 1.7 ms。
- 进度回调 `MosaicProgress`（取样 / 匹配 / 分配三阶段 + `overallFraction`），同阶段单调；可能在工作线程调用。
- `DistanceKernel` 新增可取消的 `topK(..., cancellation:progress:)`，协议扩展给了默认实现（只在前后检查），`AccelerateKernel` 占位不用改。

### 3. 亮度方差进打分 + λ 相对尺度（评审 M3）

`score = dist + λ_eff·uses(i) + μ_eff·flatness(i)`，`flatness = max(0, 1 − σ²_L/0.0004)`（0.0004 = σ_L 0.02，与 `lowDetail` 阈值一致）。
- `λ_eff = α × 本次所有格子 top‑1 距离中位数`，`α = usagePenaltyRelative` 默认 **0.1**；`μ_eff = β × 同一中位数`，`β = lowDetailPenaltyRelative` 默认 **0.04 = 0.4α**（纯色惩罚弱于"多用一次"；5 万张合成库上 μ_eff ≈ 0.003，约合每维 0.016 的 OKLab 差，低于可察觉差 ~0.02，只在有纹理的素材"几乎一样接近"时才翻转）。
- 绝对值 `usagePenalty` / `lowDetailPenalty` 只在相对系数为 nil 时生效（`withAbsolutePenalties`，测试用）。
- 中位数用下中位数，确定可复现；特征整体乘常数时结果逐格不变（T4 测试）。统计里新增 `top1MedianDistance / effectiveUsagePenalty / effectiveLowDetailPenalty`。
- 方差从 `FeatureTable` / `LibrarySnapshot` 自动带入；不传方差时 μ 不生效，旧 API 结果不变。
- 旧测试更新：两个依赖 λ 绝对值的用例（`testUsagePenaltySpreadsUsage`、`testExactMatchesWhenUnconstrained`）改用 `withAbsolutePenalties`，因为目标就是精确匹配，top‑1 中位数为 0，相对 λ 恰好为 0。

### 4. 回退链「分批加深」（评审 M1）

① top‑32 → ② 逐格扩到 top‑128（`perCellExpansionLimit` 默认 256 格，超出后的失败格直接进 ③）→ ③ 延后队列按原随机顺序**批量** top‑512，再批量 top‑2048（每组 ≤ 1,024 查询）→ ④ 剩余 **≤ 256** 格才逐格扫全库 → ⑤ 4 邻域 → ⑥ 忽略上限 → ⑦ 忽略邻域。新增级别 `batchDeepened`（rawValue 2，之后级别顺延）。
- 「误报不足」用例（1,500 张、1,200 格、cap 2、λ 0.005）：旧链 levels `[340, 597, 0, 0, 1, 262, 0]` → 新链 `[340, 598, 262, 0, 0, 0, 0]`，**放宽 262 → 0**；fallbackK = 512 的对照点也为 0。
- **补充两点（偏离评审原文，请复审）**：
  1. `perCellExpansionLimit = 256`：评审说逐格扩到 128"失败的格子很少"，但整张同色图有上万格走到这一步，每次都扫全库（成本在扫库不在 k）。超过 256 格后直接进批量 512（512 ≥ 128，质量不降）。
  2. 「忽略上限」改为**最小超额**：在放宽后的候选里先找最少的使用次数 u，再只在 uses ≤ u 的候选里选（等于上限逐级 +1）。不这样做时同色最坏情况单张最多用 30 次；改后 6 次，接近评审预计的"5 次左右"。
- 最坏情况基准（release、box 8 核、合成 5 万张、整张同色、cap = 1）：**细档 120×90：3.26 s → 1.19 s**；中档 80×60 0.53 s；1:1 80×80 0.70 s。软阈值（只在 `MOSAIC_BENCH=1` 时检查）：细档 2.5 s，中档 / 80×80 1.5 s。同色细档仍有 8,752 格忽略上限，maxUses 6，4 邻域保持不重复。这种情况下素材充足，**不显示**提示（见 7）。

### 5. 极端长图方案 A（评审 M4，决定 v0.3 补充决定 9，正式行为）

宽高比 > N:1（短边 < 长边 ÷ N）时：格边 = 短边，1 行（竖图 1 列）N 格，长边多出的部分居中裁掉；不拉伸、不补边、不拒绝、不提示。刚好 N:1 走常规分支，结果相同。`shortEdgeUnderflow` 只作内部 / 诊断标记。3000×50 粗档 → cellSize 50、cropRect (500, 0, 2000, 50)、40 个 50×50 格，导出 4000×100（严格 40:1）。竖向 50×3000 对称。按架构师建议留过"策略 enum"接口，但产品已定稿，所以只保留一种行为，没有加 enum（避免出现不会被用到的分支）。

### 6. 导出尺寸

只有向下取整一种：每格 = floor(标称 ÷ N)，导出 = 每格 × 格数，不做最后缩放。规则由架构师 + 产品经理定在 decisions-v0.3（01:12），所以**没有采纳 QA「余数分摊、误差 ≤ 1px」**；QA 已关闭该问题。曾考虑的 floor / distributeRemainder 枚举按协调人后续指示没有做。测试按 QA 新口径断言：长边 = 每格 × 格数，且在标称的 99%–100%。

### 7. 素材不足提示（决定 v0.3 / QA 缺陷 9 / 文案 §4.8）

`AssignmentStatistics.shouldShowShortageNotice`（`MosaicGeneration` 有同名转发）= `isBelowMaterialThreshold && relaxedConstraints`，**App 只看它**。纯函数 `ShortageHint.shouldShow(...)` 另有真值表测试。另外分别记录 `neighborhoodRelaxedCount`（放宽了邻域的格子：4 邻域 / 忽略上限 / 忽略邻域三级）和 `capIgnoredCount`（忽略上限 / 忽略邻域两级）。**旧说法"`relaxedConstraints` 为真就显示短提示"作废。**

### 8. 评审「建议改」

| # | 处理 |
|---|---|
| S1 | 特征提取改成单遍：每个像素线性化一次，同时累加子块均值和亮度；亮度只算 L（`OKLab.lightness`）。1 像素宽 / 高时子块共享像素，但每个像素等权重复计入，均值和方差都不变（有对拍测试） |
| S2 | `TargetSampler` 按行 `concurrentPerform`，每个任务只写自己的行，与串行逐位一致（测试） |
| S3 | `PortableMath.cbrt`：指数初值 + 3 次 Halley + 1 次 Newton，只用 IEEE 基本运算，跨平台逐位一致；与 libm 相差 ≤ 1e‑15（相对）。OKLab / CIELAB 都改用它，特征版本升到 2 |
| S4 | `FeatureSpec { colorSpace, averaging, featureVersion }`：写进 features.bin 头部；`MosaicPipeline.generate(table:/snapshot:)` 校验与取样器一致，否则抛 `MosaicError.featureSpecMismatch` |
| S5 | 内核先与堆顶比较、再查掩码；全规模 top‑32 从 0.20 s 降到 0.148 s |
| S6 | `LibrarySnapshot(table:rowLimit:sourceMask:)` = 来源 ∧ 已扫描 ∧ 未删除；cap 与供给判断都按快照张数；`generate(snapshot:)` |
| S7 | 注释已改：cap"不开放给用户"、「换一种拼法」、提示判定指向 `shouldShowShortageNotice` |
| S8 | 新增中档 80×60、1:1 80×80 同色最坏用例，加 release 软阈值 |
| O1–O4 | 没改：O1 是方案措辞问题；O2/O3 在平台层处理；O4 收益小。O5（lowDetail 进打分）已随第 3 项完成 |

### 9. QA 复验意见

1. exportSize：保持向下取整（见第 6 项）。
2. CIELAB 容差从 1e‑2 收紧到 **1e‑4**。实现改为内部双精度。参考值由 Python 双精度用同一组常数独立计算，7 组颜色，`testA03CIELabReferenceValues`。
3. `linux-core.yml` 新增 job `mosaic-core-bench`：`MOSAIC_BENCH=1`、release、上传 bench 输出。
4. 亮度方差进打分：见第 3 项。
5. 补了 A‑08、A‑19、A‑04、A‑09、A‑12、A‑20，测试名都带 A 编号，见下表。

| 编号 | 测试 |
|---|---|
| A‑03 | `ColorTests.testA03CIELabReferenceValues`（1e‑4） |
| A‑04 | `ReviewFollowUpTests.testA04DisplayP3MatrixDerivedFromPrimaries`、`testA04P3BufferIsConvertedBeforeFeatures`。实现：`RGBColorSpace`、`DisplayP3`（矩阵由原色色度和 D65 推导，不手抄常数）、`PixelBuffer.colorSpace / linearSRGB / convertedToSRGB` |
| A‑07 方差进打分 | `LowDetailPenaltyTests.*`（9 个，含 `testRelativeLowDetailPenaltyScale`、`testFlatTilesUsedLessOnSyntheticLibrary`） |
| A‑08 | `FeatureFileTests.testA08RoundTripMultipleChunks`、`testA08EncodingIsDeterministicAndLittleEndian`、`testA08DecodesHandWrittenLittleEndianBytes`，以及 `testRoundTripChunkBoundariesAndEmpty`、`testLargeFile50kRecords` |
| A‑08 错误路径 | `testFeatureVersionMismatch`、`testUnsupportedFormatVersion`、`testHeaderCorruptionAndBadMagic`、`testIncompatibleColorSpaceOrDimension`、`testTruncationKeepsValidPrefix`、`testChunkChecksumFailureKeepsPrefixBeforeBadChunk`、`testTrailingBytes`、`testAtomicWriteReplacesAndLeavesNoTempFiles`、`testFailedWriteKeepsOldFile` |
| A‑09 | `FeatureFileTests.testA09TombstoneAndCompaction`、`testA09CompactIfNeededRewritesFile`、`testA09AssignerSkipsTombstones`；快照里的 tombstone：`ReviewFollowUpTests.testS6SnapshotRestrictsRowsAndDrivesCapAndSupply` |
| A‑12 | `ReviewFollowUpTests.testA12AllOnesMaskEqualsNoMask`（top‑k 与分配都对拍） |
| A‑15 | `SupplyAndReshuffleTests.testBatchDeepeningAvoidsFalseShortage`、`testDeferredQueueDeterministicAcrossGroupSizes`、`testExhaustiveOnlyWhenFewCellsRemain`、`ReviewFollowUpTests.testM1CapIgnoredSpreadsOverflowEvenly` |
| A‑16 | 新增 `CancellationTests.testRerunAfterCancelIsIdenticalToUncancelledRun`、`testAsyncAPIUncancelledMatchesSyncAPI` |
| A‑18 | `LayoutTests.testExtremeLongImagePlanA`、`testExactlyNToOneBoundary`、`testExtremePanorama` |
| A‑19 | `ReviewFollowUpTests.testA19OverlayAlphaFormula`。实现：`Render/OverlayBlend.swift`，α 钳到 [0, 0.3]，在 sRGB 编码值上混合（与 CGContext alpha 一致），不提供颜色迁移 |
| A‑20 | `LayoutTests.testExportSizeTable`（4000/6000 × 三档 × 横/竖/1:1，99%–100%）、`ReviewFollowUpTests.testA20ExportStripsCoverWithoutOverlap`。实现：`Layout/ExportStrips.swift`，默认每条 ≤ 512 px、整行对齐，格子本身 > 512 px 时退化为 1 行格子高度 |
| A‑21 | `PerformanceTests.*`（新增中档 / 80×80 同色最坏用例、带取消令牌的全规模用例）+ CI job `mosaic-core-bench` |
| 缺陷 9 | `ReviewFollowUpTests.testShortageNoticeTruthTable` |
| M2 取消 | `CancellationTests.*`（8 个） |
| M3 尺度 | `ReviewFollowUpTests.testM3ScaleInvarianceOfRelativePenalty`、`testM3LambdaIsAlphaTimesTop1Median` |

### 10. 测试与基准（box：Debian 13 x86_64 8 核，Swift 6.2.4）

- `swift test`（debug，全部）：**138 个测试，0 失败**，执行 15.1 s → `reports/swift-test-io-cancel-debug.txt`。上一分支 81 个。
- 全规模 release → `reports/swift-bench-io-cancel-release.txt`。对比 a0102be：

| 项 | a0102be | 本分支 |
|---|---|---|
| top‑32，10,800 × 5 万 | 0.204 s | **0.148 s**（S5） |
| 完整分配（随机目标） | 210 ms | 155 ms；带方差 + 令牌 + 进度 156 ms |
| 最坏：细档同色 cap 1 | 3,256 ms，10,672 格逐格全库 | **1,185 ms**，maxUses 6 |
| 最坏：中档 80×60 / 80×80 | —（评审测 1,281 ms） | 530 / 702 ms |
| features.bin 5 万条 | — | 2.86 MB；写 15 ms，mmap 读 + 校验 7 ms |
| 取消延迟 | 不可取消 | 0.6–1.7 ms |

### 11. 待确认

1. `perCellExpansionLimit = 256` 与"忽略上限按最小超额均摊"这两处补充（第 4 项），请架构师复审。
2. 取消用 `CancellationError`，没有用 `MosaicError.cancelled`（第 2 项）。
3. α = 0.1、β = 0.04、σ²_ref = 0.0004 都是暂定值，待 A/B + TF2 目测。
4. 叠加在 sRGB 编码值上混合（与 CG 预览一致），没有在线性光里混合。方案公式没说在哪个空间做，请确认。
5. 特征版本升到 2，已有的 features.bin 会走"丢弃重建"（App 还没发布，没有影响）。
6. 软阈值只在 box 上标定过，GitHub runner（2 核）可能偏慢。第一次跑之后再定。
7. project.yml 和两份 workflow 仍**未在 macOS / GitHub 上运行过**。

## 上一分支：feat/mosaic-core（a0102be）

日期：2026-11-16（PT）　作者：全栈开发　依据：技术方案 **v0.2**（取代 v0.1）、产品决定 v0.3、文案 v1.1、QA `qa/examples`

### 本分支做了什么

1. **MosaicCore**（`Packages/MosaicCore`，swift-tools-version 6.0，Swift 6 语言模式，平台 iOS 16 / macOS 13，零依赖，不 import 任何 Apple 专有框架）
   - `Color/`：sRGB ↔ 线性（含 256 项 LUT）、OKLab（Ottosson 矩阵，默认）、CIELAB(D65)（仅保留转换 + 对照表用例）。
   - `Features/`：`PixelBuffer`（RGBA8/BGRA8、行填充）、`FeatureVector`（2×2 子块 × L/a/b = 12 维，`SIMD16` 存储）、`FeatureRecord`（+ 亮度方差、宽高比、flags）、`FeatureExtractor`（默认中心正方形裁剪、线性光平均）、`FeatureMatrix`（SoA 12×N）。
   - `Matching/`：`DistanceKernel` 协议（签名同方案 §11.1）、`ScalarSIMDKernel`（分块 + 多核、平方欧氏、(距离, 下标) 排序）、`TopKResult`、`BitMask`（并集/交集/多来源去重）、`SplitMix64` / `Xoshiro256StarStar`（自带 Lemire 有界随机与 Fisher–Yates，不用标准库随机算法）、`GreedyAssigner`（带惩罚随机顺序贪心 + 回退链）、`MaterialSupply`（200 张阈值）、`MosaicSeed`（换一种拼法的种子派生）。
   - `Layout/`：`Layout.grid(width:height:density:) -> GridLayout`（§3.6：正方形格、长边 N 格、短边向下取整、余量居中裁掉、导出尺寸）、`MosaicGrid`、`Neighborhood`、`TargetSampler`、`MosaicPipeline`（`generate` / `reshuffle`）。
2. **MosaicAccelerate**（`Packages/MosaicAccelerate`）：`#if canImport(Accelerate)` 守卫的 `AccelerateKernel` 扩展点，**目前委托给 ScalarSIMDKernel**（占位）；Metal 不做，只留注释。
3. **App 骨架**：`App/PhotoMosaicApp.swift`（SwiftUI 占位页，按 key 取文案，`KernelProvider` 注入内核）、`App/PrivacyInfo.xcprivacy`、`AppTests/`。
4. **文案**：`App/Resources/copy_v1.1.md`（原样复制）→ `scripts/gen-localizable.py` 生成 `zh-Hans.lproj/Localizable.strings`（138 个 key）与 `InfoPlist.strings`（2 个权限文案 + CFBundleDisplayName）；占位符 `{name}` → `%1$@`…；`--check` 模式进 CI。
5. **XcodeGen `project.yml`**、**CI 草稿** `.github/workflows/linux-core.yml` 与 `ios.yml`、`scripts/check-no-network.sh`（零网络 / 零远程依赖守护）。

### 关键设计决定

- **邻域**：`Neighborhood.moore(radius:)`（切比雪夫距离）/ `.vonNeumann(radius:)`（曼哈顿距离）。默认主邻域 = 8 邻域（半径 1，**所有档位**，含 120 档）；放宽邻域 = 4 邻域。每格只与**已分配**的邻居比较，邻域对称 ⇒ 未放宽的格子之间任意两格在 8 邻域内都不重复（测试对全图逐对验证）。
- **回退链**（每格逐级，记录在 `levels`）：
  ~~0 primary → 1 expandedCandidates → 2 exhaustiveSearch（逐格全库）→ 3 relaxedNeighborhood → 4 capIgnored → 5 neighborhoodIgnored~~ **已被 io-cancel 分支的「分批加深」取代（评审 M1），见上文。**
  `relaxedConstraints = relaxationCount > 0`，`relaxationCount` = 3/4/5 级格子数（**不含**只扩 k / 全库搜索）。
- **打分**：~~λ 默认绝对值 0.005~~ → 已改为相对尺度 `λ_eff = 0.1 × top‑1 中位数`，并加入亮度方差项（评审 M3，见上文）。平局 (score, dist, index) 升序不变。
- **上限**：`cap = max(1, ceil(格子数 / 可用数 × 2))`，可用数取掩码后张数；不开放给用户（`UsageCap.limited/unlimited` 只供测试/内部）。
- **可复现**：遍历顺序 = `Xoshiro256**(seed)` 的 Fisher–Yates 排列；内核结果与线程数/分块无关（测试覆盖）；同种子 + 同素材快照 + 同参数 ⇒ 逐格一致。「换一种拼法」= `MosaicPipeline.reshuffle`，种子 = `MosaicSeed.next(after:)`（SplitMix64 一步，可指定）。
- **子块均值**：默认在**线性光**中求均值再转 OKLab（物理上等于远看的混色，每块只做 1 次转换）；`.perceptual`（逐像素转 OKLab 再平均）可选。
- **网格**：M = `max(1, 短边×N ÷ 长边)` 用**整数**运算（浮点 `3 ÷ 0.05 = 59.999…` 会少算一行，有专门测试）。

### 测试结果（Linux，box：Debian 13 x86_64，8 核，Swift 6.2.4 官方 toolchain）

- `swift test`（debug，含干净构建）：**81 个测试，0 失败**；测试执行 8.0 s，含构建总计 15.9 s。完整输出：`reports/swift-test-linux.txt`。
  套件：Assignment 19、Color 8、ConstrainedMatching 7（QA 移植）、Feature 11、Layout 10、Matching 11、Performance 3、Random 6、SupplyAndReshuffle 6。
- 全规模基准（release，`reports/swift-bench-linux-release.txt`）：top‑32，10,800 格 × 5 万素材 **0.20 s**；完整分配 0.21 s；**最坏情况**（整张目标图同一颜色、cap = 1）**3.3 s**，其中 10,672 格走全库搜索。
- `MosaicAccelerate` 在 Linux 上 `swift build` 通过（空模块）。
- `xcodegen generate`：在 Linux 上用自编译的 XcodeGen 2.46.0 成功生成 `.xcodeproj`（输出到 /tmp，不入库）；scheme 含 PhotoMosaicTests + `MosaicCoreTests`；`.strings` 进 Resources，`copy_v1.1.md` 不打包。**但没有 Xcode，未做 xcodebuild 编译 / 模拟器测试**。

### 与方案的偏差 / 待架构师确认

1. ~~**回退链增加“全库搜索”一级**~~（**已解决**：评审 M1 定为分批加深，见上文）（`exhaustiveSearchBeforeRelaxing`，默认开）。原因：目标图有大片相近颜色时，相邻格的 128 近邻高度重叠，上限很快用尽；按原链会在素材充足时（测试：1,500 张、1,200 格、cap 2）有 262 格“忽略上限”，并误报 `relaxedConstraints`。代价：最坏情况（纯色目标图）在 box 上 3.3 s，iPhone 11 可能更慢，**会挤占“中档 ≤ 10 秒”**。可选方案：(a) 保留并在真机测；(b) 改成分批预算更深的 top‑k（内存换时间）；(c) 关掉，接受误报。请定。
2. ~~**极端长图短边不足一格**~~（**已解决**：产品决定 v0.3 定为方案 A，见上文）（例如 3000×50、40 档，s = 75 > 50）：方案的“正方形 + 不补边 + M ≥ 1”互相矛盾。现在是**不裁不补**，唯一一行格子取 s × 短边 的长方形区域，并置 `shortEdgeUnderflow = true`；导出尺寸仍按 M × 格边长，会改变宽高比。请定处理方式（例如限制最小短边或补边）。
3. **导出尺寸**：格边 = ⌊导出长边 ÷ N⌋（如 4000 ÷ 120 → 33 px，长边 3960）。**已由架构师 + 产品经理定为正式规则**（决定 v0.3 01:12）。
4. **子块均值用线性光**——架构师已确认保持不变。
5. ~~λ = 0.005~~ → 相对尺度（M3）。
6. **CI 文件名**：派单写 `ios-ci.yml`（一个文件两个 job），按方案 §11.3 拆成 `linux-core.yml` + `ios.yml`（便于 paths 过滤：纯 MosaicCore 改动不触发 macOS）；TestFlight 只在 `ios.yml` 末尾留注释占位，没建 `testflight.yml`。
7. ~~features.bin、条带切分、叠加混合未做~~ → io-cancel 分支已做。
8. ~~生成取消未做~~ → io-cancel 分支已做（M2）。
9. ~~亮度方差未进打分~~ → io-cancel 分支已做。
10. Swift 版本：box 与 CI 容器用 6.2（Xcode 26 自带）。XcodeGen 更新日志提到 Xcode 27.2，**当前 runner 镜像的 Xcode 版本未核实**。

### QA 骨架对齐（`qa/examples/ConstrainedMatchingTests.swift`）

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
| `materialShortageCount` | `statistics.relaxationCount` / `relaxedConstraints`；结果页提示**只看** `statistics.shouldShowShortageNotice`（= 可用 < 200 且实际放宽，决定 v0.3；io-cancel 分支新增） |
| `BitMask(count:filled:)` / `mask.set(i, false)` | `BitMask(count:allSet:)` / `mask[i] = false` |
| `SplitMix64(seed:).next()` | 相同 |
| `ScalarSIMDKernel().topK(queries:m:candidates:n:dims:k:mask:)` | 相同（另有 `FeatureMatrix` 封装） |
| 存储布局注释写“12×N 行主序” | 实际为 **SoA（维度优先）`storage[d * n + i]`**，与方案 §11.1 “SoA 12×N”一致 |
| 骨架中“换种子结果不同”为弱断言 | 移植后改为强断言（夹具是确定的，已验证不同） |
| 回退链 k32 → k128 → 4 邻域 → 忽略上限 | io-cancel 分支：k32 → k128 → 批量 512/2048 →（≤256 格）全库 → 4 邻域 → 忽略上限（最小超额）→ 忽略邻域 |

### 红线确认

未创建远程仓库、未 push、未花钱；无任何联网 API / 第三方依赖（`check-no-network.sh` 通过）。只装了 swift.org 官方 Swift 6.2.4（签名校验通过）、Debian 官方 libncurses6，以及在 /tmp 编译的 XcodeGen（仅本地验证，不入库）。
