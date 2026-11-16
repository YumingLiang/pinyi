# CHANGES

## feat/sharp-filter：「不能略糊」——生成时只用本机有 ≥ 256 px 版本的照片（hd-export-req-v0.2 F5 / hd-default-and-sharpness-v0.1 方案 1）

- **做法（不重扫全库）**：照常匹配 → 只探测**实际分到格子上**的照片（去重）→ 不合格的从候选掩码里剔掉 → 用原有匹配器（含放宽链）整图重配 → 再探测新出现的照片，最多重配 3 轮。生成前先把本会话缓存里已知不合格的剔掉，第二次生成通常 0 轮重配、0 次探测。
  - 重配是**整图**重跑（同种子、新掩码），不是只改受影响的格子：这样单张上限 / 邻域约束全局一致，「换一种拼法」也能复现。代价是每轮多一次生成耗时（见风险）。
  - 剔除后的快照存进 `GenerationProduct.snapshot`，「换一种拼法」沿用，被剔的不会换回来；新出现的照片照样探测。
- **探测**：`LocalResolutionProbing` 协议（MosaicAppCore），App 里是 `PhotoKitResolutionProbe`：`requestImage` 256×256、`.aspectFill`、`.highQualityFormat`、`.fast`、`isNetworkAccessAllowed = false`、异步；有错 / `PHImageResultIsInCloudKey` / 无图 / `PHImageResultIsDegradedKey` / 短边 < 256 一律不合格（判定在 `LocalResolutionPolicy.classify`，Linux 单测）。`.fast` 是有意的：`.exact` 会把本机小图缩放到 256，掩盖「本机只有小图」。
  - `LocalResolutionChecker`：最多 8 个请求同时在飞；Task 取消时 `cancelImageRequest` 并抛 `CancellationError`，取消后到达的结果不入缓存。
  - `LocalResolutionCache`：本会话按 localIdentifier 缓存；相册变化（`libraryDidChange`）时只清不合格条目（照片可能刚下载回本机），合格的保留。**未**持久化到索引（见风险）。
- **界面**：来源页显示 `source.excluded_low_res`「有 N 张照片手机上的版本不够清楚，没有用上」（N = 当前来源里被剔除的不同照片数，换来源后不显示）；探测期间进度页正文换成 `generate.progress.checking`「正在挑出手机上够清楚的照片，请稍等。」。
- **边界**：剔除后一张都不剩 → `NoSharpPhotosError` → `GenerationFailure.noMaterial`（现有「没有可用照片」路径），来源页仍显示 N；剩下 < 200 张时供给判断按剔除后的张数（结果页 `shortage.result` 规则不变：< 200 且放宽了约束）。重配 3 轮后仍有格子分到不合格照片（架构师 PR #5 评审 MUST）：**只把这些格子**换成「已探测且通过」的照片（`MosaicPipeline.refill`，MosaicCore 新增），忽略单张使用上限、尽量避开相邻重复（记 `.capIgnored` / `.neighborhoodIgnored`），其余格子不动；一张通过的都没有才走 `noMaterial`。最终结果里不会有未探测或不合格的照片（`unresolvedCellCount` 恒为 0），兜底格数 `finalFallbackCellCount` 进性能页附注。忽略上限只发生在这一步。
- **性能页**：新阶段 `sharpnessProbe`「清晰度探测」——各轮探测累计耗时、items = 实际探测张数；附注 `去重探测 / 缓存命中 / 排除 / 重配轮数 / 未解决格数`，性能页显示最近一次附注。重配轮的生成计时附注带「重配第 n 轮」。
- **评审跟进测试**：`SharpnessFilterTests` 新增 4 个——重度不合格（2/3、90%、只剩 1 张）下每格都是探测通过的照片；兜底只在用完重配轮数后发生；轮数内能解决时结果与直接用剔除后快照生成完全一致（没有额外放宽上限）；每轮只探测本轮新出现的照片（按轮核对探测数）。`CellRefillTests`（MosaicCore，2 个）：只换指定格子、只用允许的素材、可超上限；无可用素材抛 `noCandidates`。
- **后续（未做）**：探测结果持久化进索引（绑定 epoch），本 PR 只做会话缓存。
- **产品跟进（「可用照片」= 筛选后）**：
  - 来源页张数（全部照片 / 相簿行）在扫描完成后减去该来源已知不够清楚的张数（`SourceListLogic.excludingLowRes`）。
  - 「开始拼图」的 200 张门槛按「索引可用 − 已知不够清楚」判断（`shortage.pregenerate` 生成前提示）。
  - 生成前还不知道（第一次在该来源生成）、筛选后才不足 200 张时，结果页补显示 `shortage.pregenerate`（`AppState.postFilterShortageNotice`）；生成前已提示过则不重复。
  - 结果页 `shortage.result` 一直按筛选后的候选数判断；最后兜底补格（`refill`）也把 `availableCandidates` / 供给改为筛选后快照的张数。`GenerationOutcome.availableAfterFilter` 记录筛选后张数。
  - 「已知」= 最近一次在该来源生成时探测得出的；没探测过的照片无法预知，所以第一次只能在结果页补提示。
  - 失败页「再试一次」与「开始拼图」同一套张数：索引可用减去该来源已知不够清楚的（`AppCoordinator.retryTapped()`），200 张门槛一致。视图不再把筛选前的 `indexStatus.available` 直接传进状态机。
  - `LowResExclusion` 改为保存被排除的 ID。相册 / 索引更新后（`refreshStatus` / `refreshAlbums`）丢掉已经不在该来源里的 ID，来源页排除数和可用张数马上重算，不必等到下一次生成。
- **文案 v1.2**：`generate.progress.checking` 改为「正在挑选清楚的照片…」，`export.size.uhd.desc` 改为「放大看得最清楚。（默认）」，`source.excluded_low_res` 不变；改 `copy_v1.1.md` 后用 `gen-localizable.py` 重新生成，`--check` 通过。
- **跟进测试**（`SharpnessFilterTests` 再加 3 个）：`LowResExclusion.pruned` 只保留仍在来源里的 ID；失败后 `retryTapped` 按筛选后张数弹出 `shortage.pregenerate`；删除部分被排除的照片并完成相册同步后，来源页排除数 / 可用张数立刻更新。
- **测试**（`SharpnessFilterTests` 首版 12 个）：最终结果里没有被剔除的照片且每格都有图；N 去重、每张一次生成只探测一次；缓存避免重探（再生成 0 次探测、换拼法不重复、相册变化只清不合格）；探测中取消抛 `CancellationError`、无结果、不入缓存；并发 ≤ 8；全部不合格走 `noMaterial`；只剩 10 张时供给按剔除后判断；到达最多轮数报告未解决格数；未注入探测器时行为不变；快照剔除只动掩码；协调器来源页文案只对当前来源显示。
- **⚠️ App 层盲写**（Linux 只做 `swiftc -parse`）：`App/Adapters/PhotoKitResolutionProbe.swift`、`LiveDependencies`（注入探测器）、来源页 / 进度页 / 性能页三处视图。需真机核对：`.highQualityFormat` + 无网络时 iCloud 照片的回调形态（nil + InCloud，还是降质图）；`.fast` 返回的像素尺寸。

## feat/app-layer：导出 / 预览格子被非等比拉伸；导出记录糊格子与白格子数量

- **根因**：PhotoKit `.aspectFill` + `targetSize = N×N` 可能返回非正方形（例如 256×341）。共享取图路径 `ImagePixels.opaqueSRGB(cg, maxEdge: N)` 按长边缩到 N，变成 192×256，再画进 N×N 格子——横向拉伸，有效清晰度只有短边，人脸会变形。
- **修法**：
  - 纯函数 `CenterSquareCrop`（MosaicAppCore，Linux 单测）：按短边居中裁方（奇数余量起点向下取整）；输出边长 = min(短边, 目标)，短边不足时保持原生正方形，由绘制端等比放大，绝不非等比缩放。
  - `ImagePixels.opaqueSRGBCenteredSquare` 按该矩形 `CGImage.cropping` 后再走原有白底 sRGB 路径。`PhotoKitThumbnails` 在 `aspectFill` 时走这条路径（预览、导出、扫描取图共用）。目标图降采样仍用原来的 `opaqueSRGB`（不裁方）。
  - 紧急版导出统计两类格子：高清取不到而退回 128px `.scan` 缩略图的「糊格子」，以及完全没有图的「白格子」（无资产、取图失败、位图转换失败）。数量写入 `os_log`（category "export"，不含资产标识）和内测性能页「最近一次导出」；「复制为文本」一并带上。
  - 扫描建索引仍走 14ac550 的按长边缩小（`ThumbnailRequest.scan.centerCropToSquare = false`），避免已建索引特征失效。预览 / 导出绘制用 `scanDisplay` / 导出请求打开裁方。
- **测试**：`CenterSquareCropTests`（横/竖/正方形、奇数边、短边 < N 不放大、大于 N 缩小、非法输入）；`ExportFillStatsTests`（分类与累加）；`PerfTests.testLatestExportNote`；`ScanFeatureSnapshotTests`（256×341 合成图按长边缩到 96×128 后特征与 14ac550 快照逐 bit 相同，`featureVersion` 仍为 2；先裁方再缩小则不匹配）。


## feat/app-layer：P0 预览「第二次放大失效」（真机 32ec2b5 Internal）

- **根因**：`ResultView` 用 `MagnificationGesture().onChanged { scale = max(1, min(8, $0)) }`。手势值是**相对本次手势开始**的倍数（每次从 1 起），旧代码直接把它当绝对倍数、也没有 `onEnded` 累乘进基准——第二次捏合一开始 scale 就被设回 ≈1，图弹回原大小；上限 8 也太小，细网格放到顶也看不清单格。
- **修法**：
  - 缩放状态与规则放进 `MosaicAppCore/Preview/ZoomState.swift`（纯值类型，Linux 单测）：显示倍数 = `baseScale × liveMagnification`，`pinchEnded` 时提交；`pinchCancelled` / `panCancelled` 处理系统取消（`onEnded` 不触发）；上限 `maxScaleToFillOneCell` = max(4, 视口短边 ÷ 单格显示边长)，即至少让单格铺满屏幕；双击在上限前逐级 ×2、到顶复位；平移夹在内容边界内；视口为 0（切后台 / 过渡）时不丢倍数。
  - 可复用组件 `App/Views/ZoomableContainer.swift`（结果页现用，后续「作品查看」也用）：`Binding<ZoomState>` 由调用方持有，`@GestureState` 标记手势进行中，复位时调 cancel（`onEnded` 已提交时为空操作）。
  - 结果页的状态放在 `AppModel.resultZoom`，视图重建 / 旋转 / 切后台都不丢，换新作品时复位。
- **测试**（`ZoomStateTests`，17 个，`testZoomRegression*` 为 QA 回归）：连续 5 次 ×1.5 捏合基准 = 累乘、粗网格到上限停住；连续 5 次缩小到下限停住、再放大从当前倍数接着；中途取消的捏合 / 平移基准不变（含「先取消后 onEnded」的乱序）；双击与捏合交替；旋转 / 视口为 0 后倍数保持；上下限夹取；单格铺满屏幕上限；坏手势值忽略。

## feat/app-layer：评审 d6fa750 必须修 MF-1～MF-7、架构师 G-1（严格并发 + TSan）/ G-3（AppCoordinator）、QA 跟进

### 对照表

| 编号 | 改动 | 证据（测试 / 文件） |
|---|---|---|
| MF-1 压缩后崩溃行号错配 | 每次提交写新的 `features-<epoch>.bin`，`index.json`（formatVersion 2）记 `featuresFile`；清单 rename 成功后才删旧文件；加载/提交时清孤儿 | `IndexStoreTests.testMF1*`（4 个）：压缩提交每一步被杀都不错配、旧清单不配新特征、epoch/文件名、清单前被杀保留旧对并清孤儿 |
| MF-2 索引进 iCloud 备份 | `Application Support/Index` **目录**设 `isExcludedFromBackup`，每次启动和重建目录时都设；失败只计数不阻断 | `BackupExclusionTests`（B-12）；`AppTests.testIndexDirectoryExcludedFromBackup`（模拟器读回 resourceValues） |
| MF-3 存储协议 | `protocol IndexStore`（prepare/load/commit/discardAll），`JSONIndexStore` 实现，`IndexRepair` 与存储无关；数组行格式 `{i,d,s,r}` | `IndexStoreTests.testMF3PhotoIndexWorksAgainstAnyIndexStore`（`InMemoryIndexStore`） |
| MF-4 提交放大 | `CommitPolicy`：占空比闸门（提交耗时 × 20）+ 行数阈值 + 定时（≥300 新行才定时提交） | `CommitPolicyTests`：10 万 @111 张/秒模拟 108 次提交、占空 2.64%（原 112 次 / 56.9× n） |
| MF-5 内测配置 | 已在 10f2f1f 完成：`Internal: release` + `INTERNAL_TOOLS`（project.yml:43-46），`InfoPlist.strings` 不含 `CFBundleDisplayName`，ios.yml 矩阵检查标记 | 本次复核通过（见下「Internal 配置复核」） |
| MF-6 预览串行 + 缓存 | `ThumbnailPreviewPlan`：按素材去重、8–16 并发窗口取图、画完即丢，不留缓存 | `PreviewPlanAndMemoryTests` |
| MF-7 峰值内存 | `PeakMemoryTracker`（0.5 s 采样 `phys_footprint`，只在扫描/生成/预览/导出期间开）+ `SQLiteTriggerCheck`（评审 §3 五项触发条件，外推到 10 万）；性能页显示并可复制 | `PreviewPlanAndMemoryTests`、`testMemorySamplingDuringScanUsesInjectedClock_MF7` |
| G-1 严格并发 | 三个包 Swift 6 语言模式 + `-warnings-as-errors`；project.yml `SWIFT_TREAT_WARNINGS_AS_ERRORS`；`LockedState` 取代各处 NSLock + `@unchecked`；App 适配器改 actor / 编译器检查的 `Sendable` | 剩余清单见下；TSan 日志 `reports/tsan-linux-swift633.txt` |
| G-1 TSan CI | linux-core.yml 新 job `tsan`：每个 PR、阻断（GitHub runner 首次跑绿：run 43942739430；仍需在分支保护设为 required）；宿主先 `sysctl vm.mmap_rnd_bits=28` 再 `docker run` 钉 digest 的镜像（容器内改不了 ASLR 熵）、跳过 `PerformanceTests` / `IndexBenchTests`。**没有**加 macOS TSan workflow | `.github/workflows/linux-core.yml` |
| G-3 AppCoordinator | MosaicAppCore `@MainActor AppCoordinator` + `AppDependencies`（`PhotoLibraryClient`、`ThumbnailProviding`、`IndexStore`、`AppClock`、`LifecycleEvents`、`PreferenceStore`、`MosaicGenerating`、`MosaicExporting`、`MemoryFootprintReading`）；`.live` 在 App target（`App/Adapters/LiveDependencies.swift`），fake 在测试；无 `#if TESTING`、无单例；状态可观察（`observe(_:)` / `states()`），假时钟，测试里没有 sleep | `AppCoordinatorTests`（14 个），映射见下 |
| QA：容器钉 digest | `swift:6.3.3-noble@sha256:1ba0416b…24aa`（三个 job）；2026-11-16 用 registry API `HEAD /v2/library/swift/manifests/6.3.3-noble` 读 `Docker-Content-Digest` 复核，与 QA 所见一致 | linux-core.yml |
| QA：6.2.4 声明 | `reports/swift-test-55123ea-swift624.txt` 存在且内容为 149/0，已在下方 §13 引用；本分支另附 `reports/swift-test-app-layer-swift624.txt` | — |
| QA B-32 | 用真实 v1 `features.bin` 夹具（`ArchitectRecheckTests.v1FixtureBase64`）跑两种场景：d6fa750 旧布局、新清单指向 v1 文件头；都丢弃重建，0 个错配 | `IndexStoreTests.testB32RealV1FeaturesFileDiscardsAndRebuilds` |
| QA B-12 | 见 MF-2 | `BackupExclusionTests` |

### G-3 测试 ↔ QA 用例

| 测试（`AppCoordinatorTests`） | 用例 |
|---|---|
| `testStartResolvesRouteBeforeIndexLoadAndCleansExports_B27` | 路由先出、索引后台加载；启动清 tmp/export（B-27） |
| `testCancelMidScanKeepsProgressAndResumes_B33` | 扫描中取消保留进度、再次继续（B-33） |
| `testProgressiveReadyAt2000AndGenerateWhileScanning_B07` / `testGenerateBeforeProgressiveThresholdWaitsForScan_B07` | 2000 张渐进可用、边扫边生成（B-07） |
| `testCancelGenerationThenRegenerate_B20` | 取消生成再生成 + 换一批（B-20 / B-29） |
| `testGenerationBackgroundExpiryRerunsSameSeedOnActive_B18`、`testEnterBackgroundFlushesScanProgressToDisk_B18`、`testScanBackgroundExpiryPausesAndResumesOnActive_B18`、`testExportInterruptedByBackgroundExpiry_B18` | 进后台 / 宽限到期（B-18） |
| `testAuthorizationBecomesDeniedThenLimited_B31` | 运行中权限变拒绝 / 受限（B-31） |
| `testSaveFailuresFollowPriority_B16_B17_B30` | 保存失败优先级：无添加权限 > 空间不足 > 其他（B-16 / B-17 / B-30） |
| `testConcurrentActionsAreMutuallyExclusive` | 并发点击互斥 |
| `testMemorySamplingDuringScanUsesInjectedClock_MF7` | 峰值内存采样走注入时钟（MF-7） |
| `testLibraryChangesAreDebouncedWithInjectedClock_B11` | 相册变化去抖（B-11） |

### 剩余的 `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated`

`nonisolated(unsafe)`：**0 处**（源码与测试）。

| 位置 | 原因 |
|---|---|
| `Packages/MosaicCore/Sources/MosaicCore/Concurrency/LockedState.swift:12` | 唯一的锁封装。`Synchronization.Mutex` 需要 iOS 18，最低系统是 iOS 17；状态只在 `NSLock` 内访问 |
| `Packages/MosaicCore/Sources/MosaicCore/Matching/ScalarSIMDKernel.swift:243` `KernelPointers` | `DispatchQueue.concurrentPerform` 各迭代写互不重叠的输出区间；裸指针不能是 Sendable。生命周期由外层 `withUnsafe…` 保证 |
| `Packages/MosaicCore/Sources/MosaicCore/Matching/Assignment.swift:5` `ScanPointers` | 同上（并行扫描，每个分块写自己的槽位） |
| `Packages/MosaicCore/Sources/MosaicCore/Layout/TargetSampler.swift:50` `SamplerOutput` | 同上（按行分块写特征矩阵） |
| `App/Adapters/SystemActions.swift:58` `MainActor.assumeIsolated` | `beginBackgroundTask` 到期回调在主线程，且必须在回调返回前同步 `endBackgroundTask`，不能改成异步 `Task`；`assumeIsolated` 有运行时检查 |

原有的 App 层 `@unchecked`（`PhotoKitLibrary`、`PhotoKitThumbnails`、`ResumeOnce`、`LibraryChangeObserver`）和 `LibraryChangeObserver` 里 Timer 的 `assumeIsolated` 都已去掉：前两者改 actor，`ResumeOnce` 基于 `LockedState`，`LibraryChangeObserver` 只持有 `@Sendable` 闭包，去抖移到 `AppCoordinator`（注入时钟）。

### App target（仍是盲写，Linux 上只做 `swiftc -parse`）

- `AppModel` 变成薄适配层：`@Published state` 转发 coordinator 状态，手势转 coordinator 方法；只保留目标图解码和预览绘制。
- `.live` 依赖：`PhotoKitLibrary`（actor，add-only 授权 + `PHAssetCreationRequest` 保存）、`PhotoKitThumbnails`（actor，`stopAllCaching`）、`AppLifecycle`（scenePhase + `beginBackgroundTask`）、`UserDefaultsPreferences`、`LiveMosaicExporter`（本分支只负责清 tmp/export，条带渲染在 feat/render-export）、`PhysFootprintReader`、`JSONIndexStore` + `FileBackupExclusion`。
- 视图不再直接改 `model.flow`，全部经 coordinator。
- 盲写风险新增 R21：actor 化的 PhotoKit 适配器在 Darwin 上的 Sendable 推断（`PHFetchResult` / `PHImageRequestOptions` 只在 actor 内或 nonisolated 局部使用）；R22：`beginBackgroundTask` 回调在 iOS 26 SDK 上若已标 `@MainActor`，`assumeIsolated` 冗余但无害。

### 长循环取消检查点（App 层，MosaicCore 部分见下方 feat/mosaic-core-io-cancel §14）

| 循环 | 检查点 | 说明 |
|---|---|---|
| 扫描提特征（`PhotoIndex.synchronize`） | 每批（`batchSize`）之前 `Task.checkCancellation()`；批内 `BoundedConcurrency` 每个元素之前检查并 `cancelAll` | 取消后已完成的部分照常提交（B-33 保留进度） |
| 索引提交（`JSONIndexStore.commit`） | 不可取消 | 原子写；10 万条约 0.5 s |
| 全量元数据 diff（`applyFullDiff`） | 不可取消 | 必须整体应用；10 万条目标 ≤ 2 s（SQLite 触发条件之一） |
| 缩略图预览（`ThumbnailPreviewPlan.run`） | 每个取图窗口之前 + `BoundedConcurrency` | 新结果到达时取消旧预览 |
| 峰值内存采样 | `while !Task.isCancelled` + 注入时钟 | — |
| 导出条带循环 | 见 feat/render-export（B-34） | — |

### Internal 配置复核

`project.yml` Internal = release + `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) INTERNAL_TOOLS`，显示名「拼忆内测」；`InternalToolsMarker` 在 `#if INTERNAL_TOOLS` 内；`InfoPlist.strings` 只有两个权限说明，没有 `CFBundleDisplayName`；ios.yml 矩阵对 Release / Internal 分别断言标记有 / 无；fastlane `beta_internal` 检查显示名与标记。

### 验证（box，Linux x86_64）

- Swift 6.3.3：MosaicCore 149/0，MosaicAppCore 94（1 个基准默认跳过）/0，MosaicAccelerate 构建通过 —— `reports/swift-test-app-layer-swift633.txt`
- Swift 6.2.4：同上 —— `reports/swift-test-app-layer-swift624.txt`
- TSan（6.3.3，`--sanitize=thread`，跳过基准）：MosaicCore 145/0（合入 bb64fbb 后）、MosaicAppCore 93/0，**0 条 ThreadSanitizer 报告** —— `reports/tsan-linux-swift633.txt`
- actionlint 1.7.7 通过；App / AppTests 全部文件 `swiftc -parse` 通过；`scripts/check-no-network.sh` 通过。


## feat/app-layer：INTERNAL_TOOLS / 发布配置（基于 d6fa750，合入运维草稿 /workspace/pinyi/ios-release/）

架构师 2026-11-16 裁定：性能计时页、导出 8000 档、「马赛克测试」相簿开关只在编译条件 `INTERNAL_TOOLS` 下存在；去掉 `PERF_PAGE`。

### 改动
- **project.yml**
  - 顶层 `configs: {Debug: debug, Release: release, Internal: release}`；Internal 只多 `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) INTERNAL_TOOLS`（以及显示名），其余与 Release 相同。
  - Debug：`$(inherited) DEBUG INTERNAL_TOOLS`，显示名「拼忆调试」（三种包可同时装时一眼区分；Bundle ID 目前三者相同，见风险）。
  - `APP_DISPLAY_NAME`：Release「拼忆」/ Internal「拼忆内测」/ Debug「拼忆调试」；Info.plist `CFBundleDisplayName: $(APP_DISPLAY_NAME)`。
  - `VERSIONING_SYSTEM: apple-generic`（fastlane `increment_build_number` 需要）。
  - Scheme：`Pinyi`（test=Debug，含三组单测；archive=Release）、`Pinyi-Internal`（run/profile/archive=Internal）。旧的 `PhotoMosaic` scheme 不再生成。
- **显示名与 InfoPlist.strings**：本地化的 `CFBundleDisplayName` 会覆盖 Info.plist 值，内测包在中文系统下会显示「拼忆」。因此从 `zh-Hans.lproj/InfoPlist.strings` 删去显示名，只留两条权限说明；`scripts/gen-localizable.py` 改为校验 copy 里 `app.display_name` == project.yml Release 的 `APP_DISPLAY_NAME`（不一致则失败）。CI 也会在产物里检查 InfoPlist.strings 不含显示名。
- **App/InternalTools/**（全部 `#if INTERNAL_TOOLS`）
  - `InternalToolsMarker.swift`（草稿原样，仅首行注释）
  - `InternalToolsView.swift`：内部工具根视图，`.accessibilityIdentifier(InternalToolsMarker.id)` 实际引用标记；包括 `TestAlbumView`
  - `PerfView.swift`：从 SettingsAndPerfViews 移过来
  - `TestAlbumWriter.swift`：PhotoKit 写入 / 删除「马赛克测试」相簿，每批 50 张，JPEG 用 ImageIO 编码
- **SettingsAndPerfViews / PhotoMosaicApp**：设置页入口、「关于」连点 5 次都在 `#if INTERNAL_TOOLS` 里；`BuildFlags(internalTools:)`。
- **MosaicAppCore**
  - `BuildFlags(internalTools:)`
  - `Internal/TestAlbum.swift`：`TestAlbumPolicy`、`TestAlbumPlan` 分批、`TestAlbumProgress`、确定性合成图 `SyntheticImage`
  - 测试 `InternalToolsTests`（4 个）
- **fastlane/Fastfile**（草稿 + 改动见下）和 **fastlane/Appfile**（新增，只读 ENV）。
- **.github/workflows/ios.yml**
  - 新 job `ios-config-guard`，matrix：Pinyi/Release、Pinyi-Internal/Internal，`generic/platform=iOS`，不签名。
  - 编译后用 `strings -a` 查 `PINYI_INTERNAL_TOOLS_MARKER`：Release 有就失败，Internal 没有也失败。同时检查 `CFBundleDisplayName`。
  - 模拟器测试 job 改用 scheme `Pinyi`。
  - paths 去掉不存在的 Packages/PhotoIndex、Renderer，加 MosaicAppCore、fastlane。
  - TestFlight 注释改为 Fastfile 的 Secrets 名。提审不在任何自动流程里。

### 对运维草稿的改动和发现的问题（原文件未改）
1. 草稿 target / 工程名为 `Pinyi` / `Pinyi.xcodeproj`。仓库保持 target `PhotoMosaic`、工程 `PhotoMosaic.xcodeproj`，只把 scheme 命名为 `Pinyi` / `Pinyi-Internal`。Fastfile 按 scheme 调用，不受影响。
2. ci-ios-job.yml 用 `macos-15`。改为 `macos-26` + `DEVELOPER_DIR=/Applications/Xcode_26.6.app`，和仓库其他 job 一致。
3. project.yml.snippet 引用了未定义的 `$(PINYI_BUNDLE_ID)`。仓库保留占位 Bundle ID，Fastfile / Appfile 用 ENV `PINYI_BUNDLE_ID`。**两者必须一致**，待 AndyL 定 ID。
4. 草稿没处理 InfoPlist.strings 覆盖显示名的问题（见上）。不处理的话，Fastfile `inspect_ipa` 的「内测」检查在中文系统下能过，但用户看到的仍是「拼忆」。
5. Fastfile 用了 `Dir.mktmpdir`，但没有 `require "tmpdir"`，已补。
6. Fastfile 缺 Appfile，`match` 需要 app_identifier，已补 Appfile（只读 ENV）。
7. Fastfile 没有先生成工程，已加 `before_all { xcodegen generate }`（工程不入库）。
8. `increment_build_number` 依赖 agvtool，需要 `VERSIONING_SYSTEM=apple-generic`，已在 project.yml 加上。
9. **与决定 18 冲突**：决定 18 要求上架版保留「关于」连点 5 次进入性能页。按架构师新裁定，Release 不编译性能页，连点也无效。需要产品确认（`HiddenEntryTapCounter` 逻辑保留在 MosaicAppCore）。
10. 决定 13（测试相簿）仍待拍板：功能已实现，但 `TestAlbumPolicy.ownerApproved = false`，拍板前不显示「生成」按钮，只保留删除。

### 盲写风险（Linux 无 Xcode，未实际编译）
- XcodeGen 自定义 `Internal` 配置下，本地 SPM 包（MosaicCore / MosaicAccelerate / MosaicAppCore）的配置映射：Xcode 对未知配置名默认按 Release 编包。需要实测 Internal 包的优化级别。
- 标记防剥离：只靠 `.accessibilityIdentifier` 引用，Release 下整个文件不编译。需实测 Internal 包里 `strings` 能找到标记（CI 会验证）。
- 中文 `APP_DISPLAY_NAME` 在 build setting 和 Info.plist 中的转义。
- `generic/platform=iOS` + `CODE_SIGNING_ALLOWED=NO` 的产物路径 `build/Build/Products/<Config>-iphoneos/*.app`。
- `TestAlbumWriter` 的 PhotoKit 事务（每批 50 张；删除会弹系统确认）。
- `fastlane` 的 `export_method: "app-store"`：新版 Xcode 叫 app-store-connect，fastlane 会自动映射，需留意。
- Debug / Internal / Release 的 Bundle ID 相同，三者不能同时安装。

### 验证（Linux）
- MosaicAppCore `swift test`：60 个，1 个跳过（bench），0 失败。
- App 所有 Swift 文件分别在定义和不定义 `INTERNAL_TOOLS` 时 `swiftc -parse` 通过。
- `check-no-network.sh` OK。
- `gen-localizable.py --check` OK（140 / 2）。
- actionlint 1.7.12 OK。

## feat/app-layer（基于 55123ea）

日期：2026-11-16（PT）。依据：技术方案 v0.2、产品决定 v0.3（含 00:58、01:10、01:12 补充）、copy_v1.1（只用稳定 key）、QA 用例 B 层。
范围：T3 权限与首启引导、T4 素材来源、T5 PhotoKit 缩略图与增量更新、T9 主流程 UI，以及内部性能计时页。
**原则**：Apple 框架层尽量薄。状态机、ViewModel 逻辑、增量 diff、权限映射、计时统计都放进纯 Swift 包 `Packages/MosaicAppCore`，在 Linux 上用 fake 相册驱动 `swift test`；App target 只放 PhotoKit / UIKit 适配器和 SwiftUI 视图。

### A1. MosaicAppCore（Linux 可测，零依赖，只依赖本地 MosaicCore）

| 模块 | 文件 | 内容 |
|---|---|---|
| 文案 key | `Localization/L10nKey.swift` | 逻辑层只产出 key 或 `LocalizedLine(key, 参数)`，不产出中文。`CountFormat.grouped` 做千分位。`L10nKey` 刻意不支持字符串字面量，避免 SwiftUI `Text("…")` 产生重载歧义。测试会读取仓库里的 `Localizable.strings`，断言 key 全部存在、带格式的 key 都有 `%n$@` 占位符。 |
| 权限 / 首启 (T3) | `Permission/PhotoAuthorization.swift` | `PhotoAuthorization`（与 `PHAuthorizationStatus` 一一对应）→ `PermissionPrompt`（undetermined / limited / denied；restricted 归入 denied，见决定 7）→ `PermissionLogic.effect`（受限页：主按钮调系统选择器，次按钮「用已选的照片继续」，链接跳设置，见决定 1）。`OnboardingFlow` 共 3 屏，最后一屏按钮按授权状态显示「允许访问照片」或「开始使用」。`AppRoute.resolve` 决定启动和回前台时显示哪一页。 |
| 来源抽象 | `Library/PhotoLibraryProviding.swift` | `PhotoLibraryProviding`（授权、资产总数、按区间分批取元数据、相簿、相簿成员）、`ThumbnailProviding`、`ThumbnailRequest`（128 / aspectFill / fastFormat / fast；`isNetworkAccessAllowed` 和 `allowsCachingHighQualityImages` 是 `let false`，不能被改）。 |
| 增量索引 (T5) | `Index/PhotoIndex.swift`、`IndexManifest.swift`、`BoundedConcurrency.swift`、`ChangeDebouncer.swift`、`FeatureTable+Append.swift` | 见 A2 |
| 来源页 (T4) | `Source/SourceList.swift`、`EmptyState.swift` | 首项标题：完全访问显示「全部照片」，受限显示「已允许访问的照片」（决定 8）。扫描完成前显示「约 N 张」（资产总数，不随扫描跳动），完成后显示可用张数「N 张」（补充 Q2），相簿行规则相同。隐藏空相簿；扫描完成后也隐藏可用为 0 的相簿。受限模式下常驻「增加可用照片」。UI 只能单选，引擎保留并集能力。相簿消失时回退到全部照片，并提示 `source.album.unreadable`。空状态（决定 16）：资产为 0 → `empty.no_photos`；扫描完成但可用为 0 且有未下载 → `empty.not_downloaded`；部分未下载 → 扫描完成时提示 `scan.skipped_undownloaded`。 |
| 扫描页 | `Flow/ScanFlow.swift` | 扫描页状态：scanning / confirmingCancel / stopped / pausedInBackground / completed / failed。被杀后续扫时显示 `scan.resume`；进后台宽限到期就暂停，回前台自动继续、不提示（决定 5）。渐进可用：可用 ≥ 2,000 张时显示 `scan.progressive.*`。用户主动停止后不会自动继续。 |
| 主流程 (T9) | `Flow/MainFlow.swift`、`GenerationMachine.swift`、`GenerationRunner.swift`、`HiddenEntry.swift` | 见 A3 |
| 计时 | `Perf/PerfRecorder.swift`、`PerfReport.swift` | 见 A4 |
| 色块预览 | `Preview/PreviewRenderer.swift` | 用素材特征的 2×2 子块颜色画出每格（OKLab 或 CIELAB → sRGB），在缩略图取回前先显示。测试验证每格颜色与素材原色误差 ≤ 1/255。 |

### A2. 增量索引 `PhotoIndex`（actor）

- **全量元数据 diff**（决定 11）：分批 `assetMetadata(in:)`，每批 2,000 条，不把全部 PHAsset 转成数组。按 id 比较 `modificationDate`：
  - 新增 → pending；
  - 修改 → 旧行 tombstone + pending；
  - 删除 → tombstone + 删条目；
  - `unavailableLocal` / `failed` 每次全量 diff 都重试（对应「重新检查」）。
- **扫描**：
  - 每批 300 张（夹到 1–500），缩略图并发 24（夹到 ≤ 32）；生成期间降到 4，切换在下一批生效（方案 §5）。
  - 下一批会先 `startCaching`，本批处理完 `stopCaching`。
  - 宽高比用 PHAsset 像素尺寸覆盖（评审 O3）。
- **落盘**：先写 `features.bin`（MosaicCore 原子写），再写 `index.json`（`.atomic`）。整表重写是 O(n)，所以累计新行 ≥ max(1000, 10% 表长) 或距上次落盘 ≥ 8 s 才落盘一次；扫描结束、取消、出错时都会落盘。
- **崩溃一致性**（加载时修复）：
  - 清单引用不到的行 → tombstone（孤儿行：features 已写、清单未写）；
  - 清单引用了超出文件长度或已 tombstone 的行 → 条目回到 pending。
- **损坏恢复**：
  - `features.bin` 截断或块校验失败 → 保留有效前缀，丢失行对应的资产重扫；
  - 头部损坏、特征版本变化、`index.json` 损坏或版本不符 → 删除两个文件，全量重建（决定 (5)：重建流程放在 App 层）。
- **压缩**：扫描结束时，若空洞率 > 20% 就压缩，并按 `oldToNew` 重映射清单行号。测试会逐行校验特征颜色与资产对应。
- **取消**（Task.cancel / 用户停止 / 后台到期）：已完成的批次会落盘，`scanInProgress` 保持 true，下次显示 `scan.resume`，只扫剩余部分。
- **快照**：`snapshot(for: .allPhotos | .album(id))` → `LibrarySnapshot`（来源 ∧ 已扫描 ∧ 未删除）+ 行号到 localIdentifier 的映射（渲染取图用）。相簿打不开时抛 `PhotoIndexError.albumUnreadable`。

### A3. 生成流程 `GenerationMachine`（纯 reducer，平台层执行 Effect）

- 「开始拼图」：
  - 可用 < 200 → 先显示 `shortage.pregenerate`，可继续或返回，不阻止生成（决定 2）；
  - 0 张 → 进入 noMaterial（正常情况下已被 `GenerateGate` 的空状态拦住）。
- 每次运行有递增的 runID，**过期运行的结果和错误一律忽略**（例如取消后才到的回报）。
- 生成中点「取消」→ 弹确认，生成在后台继续 → 确认后取消。由「换一种拼法」触发的运行被取消时，回到上一结果。
- **CancellationError 不算失败**（决定 (2)）：`GenerationFailure.classify` 返回 nil，不进失败页、不记诊断错误。系统取消按挂起处理。
- 后台：进后台（宽限到期）→ 取消并挂起 → 回前台用**同一种子**自动重跑。自动重跑也失败时，回到设置页并提示 `generate.auto_retry_failed`（决定 5）。普通失败 → `generate.failed.*`。
- 「换一种拼法」：种子取 `MosaicSeed.next(after:)`，复用同一快照，参数不变（决定 4）。结果页 `shortage.result` 直接取 `MosaicGeneration.shouldShowShortageNotice`（可用 < 200 且实际放宽了约束）。
- `GenerateGate`：
  - 有空状态 → 显示空状态；
  - 扫描完成，或当前来源可用 ≥ 2,000 → 开始；
  - 否则跳扫描页等待。
- `GenerationRunner`：调 `MosaicPipeline.generate(snapshot:seed:progress:) async`，进度用 `overallFraction`，阶段计时写入 `PerfRecorder`。

### A4. 内部性能页

- `PerfRecorder` 线程安全，容量有界，时钟可注入。
- 阶段：相册 diff、取缩略图、特征提取（累计 CPU）、索引提交、压缩、索引加载、目标图解码、生成（取样 / 匹配 / 分配 / 总计，由 `GenerationPhaseTimer` 从内核进度回调切分）、预览绘制。
- `PerfReport` 给出每个阶段的次数、总计、中位数、p90、最大值和吞吐，可导出纯文本（「复制为文本」只写剪贴板，零网络）。
- 扫描吞吐的分子**包含 iCloud 跳过的张数**（性能口径：跳过的也计入）。
- 入口（决定 18）：
  - 编译条件 `PERF_PAGE`（目前只在 Debug 打开）时，设置页显示「性能测试」；
  - 「关于」页 1 秒内连点版本号 5 次也能进入（`HiddenEntryTapCounter`）。

### A5. App target（适配器 + 视图，⚠️ 全部是盲写，Linux 上只做过 `swiftc -parse` 语法检查）

```
App/
├─ PhotoMosaicApp.swift            # @main + KernelProvider + PERF_PAGE 开关
├─ Adapters/
│  ├─ PhotoKitLibrary.swift        # PhotoLibraryProviding：PHAsset / PHAssetCollection
│  ├─ PhotoKitThumbnails.swift     # ThumbnailProviding：PHCachingImageManager（128 / aspectFill / fastFormat / fast / 不联网）
│  ├─ ImagePixels.swift            # CGImage → 白底 sRGB RGBA8 PixelBuffer；ImageIO 目标图降采样（≤ 2048，带 EXIF 方向）
│  ├─ SystemActions.swift          # 打开设置 / presentLimitedLibraryPicker / beginBackgroundTask 包装
│  └─ LibraryChangeObserver.swift  # PHPhotoLibraryChangeObserver → 2 s 去抖 → 全量 diff
├─ Models/AppModel.swift           # @MainActor ObservableObject：只转发到 MosaicAppCore 并执行副作用
├─ Rendering/MosaicPreviewRenderer.swift  # 结果页预览：先显示色块，再用缩略图逐格绘制 + 原图叠加 α
└─ Views/                          # RootView / Onboarding / Permission / MainFlow（目标图 → 来源 → 设置 → 进度 → 结果）/ Scan / Empty / Settings / About / Perf
```

- `project.yml` 的改动：
  - 新增本地包 `MosaicAppCore`，App 和 AppTests 都依赖它；
  - scheme 的 test 加上 `MosaicAppCore/MosaicAppCoreTests`；
  - PhotoMosaic 的 Debug 配置加 `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) DEBUG PERF_PAGE`。
- `linux-core.yml`：新增 step「Test MosaicAppCore」（`swift test --parallel`），用同一个 `swift:6.3.3-noble` 容器。
- AppTests 新增：授权映射、透明像素合成到白底、bundle 里所有 key 都能查到、`LocalizedLine` 格式化。

### A6. 与技术方案的偏离 / 未做

1. **`index.sqlite` → `index.json`**：为了零依赖并能在 Linux 上测试，用原子写入的 JSON 清单。Linux 上 10k 条时每次提交约 34 ms（JSON 编码占主要部分）。若真机 10 万张提交过慢，再换 SQLite，只需改 `PhotoIndex.commit/load`。
2. **64px 图集没做**：方案 §2.5 写「特征可由 64px 图集重算，不必访问 PhotoKit」。目前丢弃重建时直接重新请求 PhotoKit 缩略图（逻辑正确，重建较慢）。
3. **token 增量**（`fetchPersistentChanges`）没做：决定 11 允许 TF1 只做全量 diff。
4. **预览没用 CATiledLayer**：MVP 用一张整图（长边 ≤ 约 2400 px）加缩放手势。保存 / 分享 / 4000 / 6000 导出属于 T10/T11，不在本卡范围。
5. 性能页没有导出基准（8000 摸底，决定 12），等导出卡完成后再加。
6. `Application Support/Index` 没有设置 `isExcludedFromBackup`（索引可重建，应排除出 iCloud 备份），待补。

### A7. 盲写风险清单（macOS CI 首次跑通后逐条核对）

| # | 位置 | 不确定点 |
|---|---|---|
| R1 | `PhotoKitLibrary` | `PHFetchOptions` 谓词 `mediaType == %d` 与 `includeHiddenAssets`；同一个 `PHFetchResult` 跨多次分批调用是否稳定（目前每轮 diff 在 `assetCount()` 时刷新）；智能相簿子类型选了 favorites / selfPortraits / depthEffect；相簿多时逐个 fetch 计数的耗时 |
| R2 | `PhotoKitThumbnails.requestImage` | `.fastFormat` 是否只回调一次（已用 ResumeOnce 防二次 resume）；`PHImageResultIsInCloudKey` 与 image == nil 的组合判断；aspectFill + `.fast` 返回的尺寸可能不是 128 正方形（特征提取默认取中心正方形，影响小）；回调线程 |
| R3 | `ImagePixels.opaqueSRGB` | premultipliedLast 上下文先铺白再 draw，结果当作非预乘 RGBA 使用（全不透明时两者等价）；P3 → sRGB 依赖 CG 的颜色匹配 |
| R4 | Swift 6 严格并发 | PhotoKit 非 Sendable 类型（`PHImageRequestOptions`、`PHAsset`）被闭包捕获；几处 `@unchecked Sendable`；`beginBackgroundTask` 到期回调与 `Timer` 回调里用了 `MainActor.assumeIsolated`（这两个都应在主线程回调） |
| R5 | `LibraryChangeObserver` | 在 init 里 register、deinit 里 unregister；受限选择器改动后能否收到回调 |
| R6 | `SystemActions.presentLimitedLibraryPicker` | 通过 connectedScenes / keyWindow 找最上层 VC；用的是无回调版本（结果靠变化回调） |
| R7 | `PhotosPicker` + `loadTransferable(type: Data.self)` | HEIC / ProRAW / 大图的数据与内存；ImageIO `kCGImageSourceThumbnailMaxPixelSize` 2048 + `WithTransform` 方向处理 |
| R8 | SwiftUI 呈现 | 进度全屏、确认框、alert 用 `.constant(…)` 绑定，由状态机驱动（系统的"点外面关闭"会被忽略）；扫描 sheet、空状态 sheet、全屏进度三者可能同时呈现冲突 |
| R9 | 废弃 API | `onChange(of:) { new in }`、`.navigationBarLeading` 在 iOS 17 SDK 下有废弃警告（开了 warnings-as-errors 就会挂） |
| R10 | 本地化 | `Text(_: L10nKey)` 重载；`String(format:arguments:)` 用 NSString 参数配 `%1$@` |
| R11 | XcodeGen | scheme 里 `package: MosaicAppCore/MosaicAppCoreTests` 语法；`configs: Debug:` 覆盖 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 时 `$(inherited) DEBUG` 是否重复或丢失 |
| R12 | 构建配置 | `PERF_PAGE` 只在 Debug 打开；TestFlight 内部包若走 Release，需要新增 Internal 配置（决定 18 要求内部 TF 默认显示） |
| R13 | 模拟器上跑包测试 | `L10nKeyTests` 用 `#filePath` 读仓库里的 `.strings`，模拟器进程应能读宿主路径，需核对；读不到时改为跳过 |
| R14 | 后台 | 扫描在 `beginBackgroundTask` 宽限期内继续请求 PhotoKit 是否被允许或节流；到期取消后落盘是否能在宽限期内完成 |
| R15 | 内存 / 主线程 | 细档 + 预览 cellPixels ≤ 32（长边 ≤ 约 2400 px，约 17 MB）；`refreshAlbums` 在 MainActor 上逐相簿取成员（相簿多时卡顿，应移到后台） |
| R16 | `AppModel` | `Task.detached` 里捕获 `[weak self]` 再 `MainActor.run`；`GenerationProduct` 跨 actor 传递（已声明 Sendable） |

### A8. 测试

- `Packages/MosaicAppCore`：**56 个测试（55 个通过，1 个基准默认跳过），0 失败**。Swift 6.3.3（CI 同版本）、6.2.4、6.4.2 三个工具链都通过；`--parallel` 也通过。覆盖：
  - 权限映射与首启；
  - diff（新增 / 修改 / 删除 / 重试 / 重复 id）；
  - 索引：首扫计数与跳过、增量 tombstone、压缩重映射（逐行校验特征）、中途取消后新实例续扫且只扫剩余、特征版本变化重建、清单损坏重建、孤儿行、截断前缀恢复、并发上限与生成期间降并发、相簿快照与打不开、全部未下载的空状态及重新检查、空相册、计时；
  - 来源页与闸门、扫描状态机、主流程导航、生成状态机（过期 runID、后台同种子重跑、自动重跑失败提示、CancellationError 静默、换一种拼法取消回结果）；
  - 端到端生成（同种子可复现、cellAssetIDs、素材不足提示、Task 取消抛 CancellationError）、色块预览、计时与报告、有界并发。
- `Packages/MosaicCore`：149 个测试，0 失败（6.3.3，未改动）。
- `MOSAIC_BENCH=1 swift test -c release --filter IndexBenchTests`（fake 缩略图，只看簿记开销）：10k 张总耗时约 410 ms，其中提交 379 ms（11 次）、特征提取 48 ms。**Linux 数字不能作为 iPhone 11 首扫 ≤ 90 秒的证据**，真机瓶颈在 PhotoKit 取图。
- `check-no-network.sh` OK；`gen-localizable.py --check` OK；actionlint 1.7.12 两个 workflow 都 rc 0；App / AppTests 全部 `swiftc -parse` 通过（Linux 上无法类型检查 SwiftUI / Photos）。

## feat/mosaic-core-io-cancel（基于 a0102be）

日期：2026-11-16（PT）　依据：技术方案 v0.2、产品决定 v0.3（含 01:10 / 01:12 补充）、架构师评审 `reviews/mosaic-core-a0102be.md`、QA `qa/a-layer-coverage.md`、文案 copy_v1.1（已再次同步）。

### 1. features.bin（格式 v1）— `Sources/MosaicCore/Storage/`

全部小端。`FeatureFile.write/read/decode/readHeader/compactIfNeeded`，`FeatureTable`（SoA 矩阵 + 方差 + 宽高比 + flags + `FeatureSpec`），`CRC32`（自实现 IEEE，"123456789" → 0xCBF43926）。

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 8 | magic `"PMFEAT\0\0"` |
| 8 | 2 | 容器格式版本 = 1 |
| 10 | 2 | 头部长度 = 64 |
| 12 | 4 | 特征版本（`MosaicCoreInfo.featureVersion`，本分支 **1 → 2**：cbrt 换成不依赖 libm 的实现 + 单遍方差） |
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
- 「误报不足」用例（1,500 张、1,200 格、cap 2、λ 0.005）：旧链 levels `[340, 597, 0, 0, 1, 262, 0]` → 新链 `[346, 256, 598, 0, 0, 0, 0]`（按 `reports/swift-test-linux-6.3.3-debug.txt` 实际输出核对；ca6a4ca 版此处误写为 `[340, 598, 262, …]`），**放宽 263（1 格 4 邻域 + 262 格忽略上限）→ 0**；fallbackK = 512 的对照点也为 0。
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
| S3 | `PortableMath.cbrt`：指数初值 + 3 次 Halley + 1 次 Newton，只用 IEEE 基本运算，不依赖 libm；与 libm 相差 ≤ 1e‑15（相对）。OKLab / CIELAB 都改用它，特征版本升到 2。**整条特征链不保证跨平台逐位一致**：`SRGB.linearLUT` 仍用 libm `pow` 生成（glibc / Darwin 可能差 1 ulp）。按架构师拍板 (6)，只保证同平台确定，跨平台用容差比较（分配差异率 ≤ 2%、平均距离相对差 ≤ 1e‑3）。ca6a4ca 版写的「跨平台逐位一致」已撤回 |
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
| A‑16 同种子可复现 | `AssignmentTests.testSameSeedSameResultDifferentSeedDifferentResult`、`ConstrainedMatchingTests.testSameSeedSameInputYieldsIdenticalAssignment`、`SupplyAndReshuffleTests.testReshuffleChangesResultSameSeedReproduces`；前提（与线程/分组无关）：`MatchingTests.testTopKIsSortedAndParallelEqualsSerial`、`SupplyAndReshuffleTests.testDeferredQueueDeterministicAcrossGroupSizes`、`ReviewFollowUpTests.testS2ParallelSamplerEqualsSerial`（源码注释均已标 A‑16）。**（ca6a4ca 版误写成 CancellationTests，已更正）** |
| A‑18 | `LayoutTests.testExtremeLongImagePlanA`、`testExactlyNToOneBoundary`、`testExtremePanorama` |
| A‑19 | `ReviewFollowUpTests.testA19OverlayAlphaFormula`。实现：`Render/OverlayBlend.swift`，α 钳到 [0, 0.3]，在 sRGB 编码值上混合（与 CGContext alpha 一致），不提供颜色迁移 |
| A‑20 | `LayoutTests.testExportSizeTable`（4000/6000 × 三档 × 横/竖/1:1，99%–100%）、`ReviewFollowUpTests.testA20ExportStripsCoverWithoutOverlap`。实现：`Layout/ExportStrips.swift`，默认每条 ≤ 512 px、整行对齐，格子本身 > 512 px 时退化为 1 行格子高度 |
| A‑21 | `PerformanceTests.*`（新增中档 / 80×80 同色最坏用例、带取消令牌的全规模用例）+ CI job `mosaic-core-bench` |
| 缺陷 9 | `ReviewFollowUpTests.testShortageNoticeTruthTable` |
| 原缺陷 7 / M2 取消（方案 §5.1，非 A 编号） | `CancellationTests.*`（8 个）；其中 `testRerunAfterCancelIsIdenticalToUncancelledRun` 是「取消不破坏可复现」的附加覆盖，不替代 A‑16 |
| M3 尺度 | `ReviewFollowUpTests.testM3ScaleInvarianceOfRelativePenalty`、`testM3LambdaIsAlphaTimesTop1Median` |

### 10. 测试与基准（box：Debian 13 x86_64 8 核，Swift 6.2.4；第 12 项起另用 6.3.3 复跑）

> ⚠️ 以下 Linux 耗时只防回归，**不能**作为 iPhone 11 性能退出线的证据，需真机验证。


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

1. ~~`perCellExpansionLimit` 与最小超额~~ → 架构师已同意（拍板 (1)），并补了同种子重跑断言（第 13 项）。
2. ~~取消用 `CancellationError`~~ → 架构师已同意（拍板 (2)）：App 先匹配 `is CancellationError`，按正常取消处理，不弹错误、不计诊断错误。
3. α = 0.1、β = 0.04、σ²_ref = 0.0004、兜底尺度 1e‑3 都集中在 `TuningDefaults`，**待真机调参**（架构师拍板 (3)）。
4. ~~叠加空间~~ → 架构师已同意在 sRGB 编码值上混合（拍板 (4)）；两图颜色空间不一致时先转 sRGB（第 13 项）。
5. 特征版本升到 2，已有的 features.bin 走"丢弃重建"——架构师已同意（拍板 (5)）。MosaicCore 只给信号，重建编排在 App 层（`feat/app-layer` 分支）。
6. 软阈值只在 box 上标定过；bench job 现在只记录不阻断（见第 12 项），GitHub runner 跑过一次后再定阈值。
7. project.yml 和两份 workflow 仍**未在 macOS / GitHub 上运行过**（actionlint 已校验通过）。
8. **Linux 耗时不能作为 iPhone 11 性能退出线（中档 ≤ 10 秒、1 万张首扫 ≤ 90 秒）的证据，必须真机验证。** 本文件里的所有毫秒数都来自 Linux x86_64，只用来防止回归。

### 12. QA 复验 ca6a4ca 的后续修正（`qa/reports/retest-ca6a4ca.md`）

1. **A‑16 对照**：改为同种子可复现那组测试，测试源码的注释也标上了 A‑16；取消测试改标「原缺陷 7」（见第 9 项表格）。
2. **过时说法**：旧节的偏差 1、2、10 改成最终描述（分批加深、方案 A、钉版本）；`relaxationCount` 的级别号更新为 4/5/6。全文搜过 `shortEdgeUnderflow`、`exhaustiveSearchBeforeRelaxing`、「不裁不补」、「放宽即提示」，剩下的都只出现在明确标为历史 / 已作废的句子里。
3. **CI Swift 版本**：`linux-core.yml` 两个 job 钉 `swift:6.3.3-noble`。
   - 2026-11-16 通过 Docker Hub registry API 匿名查询，返回 200；index digest `sha256:1ba0416b…24aa`，amd64 + arm64。
   - 同时存在的还有 6.2.4-noble、6.4.2-noble，6.4.2 是最新稳定版。
   - 选 6.3.3 而不选 6.4.2：要与 macOS runner 默认的 Xcode 26.6（自带 Swift 6.3.3）保持同一编译器，避免 Linux 通过、Xcode 不通过（6.4 的新语法 / 诊断 Xcode 26 不认）。
   - box 上装了 swift.org 官方 6.3.3（debian12 包，GPG 签名校验通过），复跑 `swift test` **138/0**（`reports/swift-test-linux-6.3.3-debug.txt`），release bench 见 `reports/swift-bench-linux-6.3.3-release.txt`；6.2.4 也复跑通过；QA 用 6.4.2 跑过 138/0。
   - bench job：`continue-on-error: true`；软阈值默认只打印 `::warning::`，`MOSAIC_BENCH_ASSERT=1` 才断言；`[bench]` 摘要写进 job summary。
4. **ios.yml runner**：`macos-26` 是官方标签（arm64 标准 runner，当前 = `macos-latest`）。
   - 镜像 20261102.0473.1（macOS 26.7.2）默认 Xcode **26.6（17F113，Swift 6.3.3，iOS 26.5 SDK）**，路径 `/Applications/Xcode_26.6.app`，另有 26.0.1–26.5；Xcode 27 只在预览 runner `xcode-27` 上。
   - 现在用 `DEVELOPER_DIR` 钉 26.6，路径不存在时直接报错。
   - actionlint 1.7.12（最新版，官方二进制，sha256 校验通过）对两份 workflow 退出码 0；QA 的 1.7.7 内置标签表没有 macos-26，所以在 `.github/actionlint.yaml` 里声明，1.7.7 也通过。
   - 来源：<https://github.com/actions/runner-images>（README 与 `images/macos/macos-26-arm64-Readme.md`）、<https://docs.github.com/en/actions/reference/runners/github-hosted-runners>、<https://hub.docker.com/_/swift>、<https://forums.swift.org/t/announcing-swift-6-3-3/87888>（"Xcode 26.6 contains Swift 6.3.3"）。
5. 顺手修了 Swift 6.3.3 报的一个测试告警（`var` → `let`）。

### 13. 架构师复审 ca6a4ca 的必须修 / 拍板补测 / 建议（`reviews/mosaic-core-ca6a4ca.md`）

| 项 | 处理 | 位置 / 测试 |
|---|---|---|
| **MF-1** 性能软阈值硬断言 | 改成**同一次运行内**的相对值：最坏耗时 ÷ 同次 top‑32 基准（10,800 × 同一库，预热后计时）。超过 box 标定值 × 1.5（细档 7.5×、中档 3.5×、80×80 4.5×）就打印 `[bench][WARN]` 和 `::warning::`，不失败。绝对毫秒阈值只在 `MOSAIC_BENCH_ASSERT=1` 时断言。bench job 设了 `continue-on-error`。box 上 6.3.3 release 实测 7.85× / 3.83× / 4.53×（`reports/swift-bench-linux-6.3.3-release.txt`） | `PerformanceTests.worstCase`、`linux-core.yml` |
| **MF-2** 中位数为 0 时 λ/μ 失效 | 新增 `PenaltyScale`，尺度按顺序取：① top‑1 > 0 的格子上的下中位数 → ② 全为 0 时取第 k 名距离（k = 32，候选不足时取最后一个有限值）的下中位数 → ③ 仍为 0 时用 `degeneratePenaltyScale`（默认 1e‑3，约合每维 OKLab 差 0.009；此时距离全为 0，这个值只起分摊作用）。统计里新增 `penaltyScale` 和 `penaltyScaleSource`；`top1MedianDistance` 改为「正值中位数」 | `Assignment.swift` 的 `PenaltyScale`；`ArchitectRecheckTests.testMF2MostlyBlackTargetWithIdenticalBlackTileKeepsPenalties`（60% 纯黑目标 + 同色纯黑 / 纯白图）、`testMF2AllZeroTop1FallsBackToKthMedian`（整张纯白）、`testMF2AllDistancesZeroUsesDegenerateConstant`（全库与目标完全相同，与 λ = 0 对照） |
| MF-2 附：0.0004 两处重复 | 新增 `TuningDefaults`（α、β、σ²_ref、兜底尺度），作为唯一来源，`AssignmentConfiguration` 和 `FeatureExtractor.lowDetailVarianceThreshold` 都从这里取默认值，并标「待真机调参」 | `Matching/TuningDefaults.swift`；`testTuningDefaultsSingleSource` |
| **MF-3** 文档 / 注释 | ① M1 分布改为实测的 `[346, 256, 598, …]`（第 4 项）；② 撤回「跨平台逐位一致」（第 8 项 S3、`PortableMath` 文件头、`SRGB.linearLUT` 注释）；③ `Assignment.swift` 里 `shouldShowResultHint` 改为 `shouldShowShortageNotice` / `ShortageHint.shouldShow` | — |
| 拍板 (1) / S‑6 | 补最小超额路径的同种子重跑断言，另测不同内核分块（3 / 777）和组大小 7 下结果逐格一致 | `testMinimalOverflowPathIsReproducible` |
| T‑1（探针 P4） | 在批量加深阶段（assigning 进度 > 主轮格数）取消，同种子重跑逐格一致 | `testCancelDuringBatchDeepeningThenRerunIsIdentical` |
| T‑2（探针 P5） | 带方差、缩放 ×4 / 3 / 1.7 / 0.3 / 10，逐格一致 | `testM3ScaleInvarianceWithVarianceAndNonPowerOfTwoFactors` |
| 拍板 (2) | 已同意；App 层的映射在 `feat/app-layer` 分支实现 | — |
| 拍板 (3) | `TuningDefaults` 集中管理（见上） | — |
| 拍板 (4) / S‑1 | `OverlayBlend.blend(tile:target:)`：两图颜色空间不一致时都转到 sRGB 再混合，结果标 sRGB | `testOverlayConvertsMismatchedColorSpaces` |
| 拍板 (5) / S‑7 | 用 d6ef584（featureVersion = 1）的**旧写入器**生成 3 条记录的真实文件（248 B），以 base64 嵌进测试（不改 Package.swift、不加资源）。v2 引擎两种恢复模式都抛 `featureVersionMismatch(found: 1, …)` + `.discardAndRebuild`；按 v1 显式读取时数据完好，证明 fixture 不是坏文件 | `testRealV1FileIsDiscardedAndRebuilt` |
| 拍板 (6) | 不要求跨平台逐位一致（见 MF-3） | — |
| S‑2 进度回调在锁内 | `ProgressCounter` 锁内只递增；回调由单独的上报锁串行，中间进度用 `try()`，拿不到锁就跳过，工作线程不阻塞；只报更大的值，所以单调；最后一次阻塞上报，保证 100% 送达 | `testSlowProgressCallbackStaysMonotonicAndCompletes`（每次回调 sleep 2 ms，结果与无回调相同） |
| S‑3 async 注释 | 改为「跑在全局并发池，会占住一个协作线程」，建议放在 `Task.detached` 或专用队列中执行 | `MosaicPipeline.swift` |
| S‑4 / S‑5 | 新增 `generate(snapshot:) async`、`reshuffle(snapshot:)`（同步 + async）；`reshuffle(library:)` 增加 `lightnessVariance` 参数，不再丢方差；`FeatureMatrix` 入口标为「测试 / 内部用」，App 只走 snapshot | `testSnapshotAsyncAndReshuffleKeepVariance` |
| S‑8 取消测试时序 | `testSwiftTaskCancellationAsyncAPI` 去掉固定 sleep，改为在第一次匹配进度回调里停住，等测试发出取消后再继续；跨线程延迟测试的回调也等取消真正发出才返回。快机器上也不会先跑完 | `CancellationTests` |
| O‑a / O‑b / O‑c | 没做（可选项）。O‑c 的已知取舍已写进方案 §3.4 | — |

测试：box 上 Swift 6.3.3 `swift test` **149 个测试，0 失败**（ca6a4ca 为 138 个，新增 11 个：`ArchitectRecheckTests`），源码和测试都没有 warning；6.2.4 也复跑 149/0（日志 `reports/swift-test-55123ea-swift624.txt`：55123ea、Swift 6.2.4、`--no-parallel`、Executed 149 tests, 0 failures）。actionlint 1.7.12 和 1.7.7 都通过。


### 14. PR #1 iOS CI 取消延迟 805 ms：根因与修复

**结论：检查粒度不够，不是单纯 runner 抖动。**
- 证据：
  - 距离内核（`ScalarSIMDKernel`）原来只在**每组查询之前**检查取消。一组 = 16 个查询 × 全部候选（2 万）× 12 维；取消后，各线程手上正在算的那一组要跑完才停。
  - 同一份 CI 日志（run 43934322051，模拟器 Debug）里，「40x30 × 5000 候选」中途取消是 112 ms。每组工作量与候选数成正比，2 万候选应约为 4 倍 ≈ 450 ms；再加上 3 核 runner 被 8 个工作线程争用，实测 805 ms 与此吻合。
  - box（8 核，SwiftPM Debug，Swift 6.3.3）各跑 3 次，同一测试：旧代码（3f96b30）17.5 / 17.9 / 18.9 ms，新代码 1.33 / 1.29 / 1.12 ms，约 14 倍。`Task.cancel` 路径：旧 15.2 / 16.4 / 16.9 ms，新 1.78 / 1.30 / 1.51 ms。
- 修复：
  - 内核在**每个候选块（1024 个候选）之前**也检查一次，粒度细约 20 倍。中途停下的组不计进度、不写输出，整体抛 `CancellationError`。
  - 逐格扩展（`fallbackK`）原来调的是不带令牌的 `topK`，扫全库期间无法取消；现在也传令牌。
- 测试定稿：CI 硬判逻辑，墙钟只记录。
  - `testKernelChecksCancellationBetweenCandidateTiles`：第 3 次检查时要求停止，必须恰好检查 3 次、未完成；不取消时检查次数 = ⌈5000/1024⌉ = 5。
  - `testSerialKernelStopsAtNextCheckpointAfterCancel`：串行内核在第 3 批的进度回调里同步取消，之后不得再有任何进度事件，抛 `CancellationError`，无结果。
  - `testCancellationLatencyFromAnotherThread`：硬判 `CancellationError`、无结果、取消后进度事件 ≤ 线程数。墙钟只打印，≥ 250 ms 时输出 `::warning::`，不失败。`testSwiftTaskCancellationAsyncAPI` 同样处理。

**长循环取消检查点清单（MosaicCore）**

| 循环 | 检查点 | 最坏间隔（10 万素材） |
|---|---|---|
| top-k 匹配（`ScalarSIMDKernel`，并行） | 每组查询之前 + 每个候选块（1024）之前 | 16 查询 × 1024 候选 |
| 第 1 轮贪心分配 | 每 `cancellationCheckInterval`（64）格 | 64 格（每格只查自己的 top-k 列表） |
| 逐格扩展到 `fallbackK` | 扩展前检查 + 内核内每个候选块 | 1 查询 × 1024 候选 |
| 分批加深（batch 512 / 2048 回退） | 每组之前；内核内每个候选块；组内每 64 格 | 512 查询 × 1024 候选 |
| 全库逐格搜索（exhaustive，≤ `exhaustiveCellLimit` 格） | 每格之前 | 1 格 × 全库（10 万 × 12 维 ≈ 1.2 M 次乘加，Release 约 1 ms） |
| 目标图取样（`TargetSampler`） | 取样前后 | 一次取样（≤ 120×90 格，毫秒级） |
| 生成管线（`MosaicPipeline`） | 入口、取样后、分配内各点 | 同上 |
| features.bin 读写 | 不可取消（单次 mmap / 原子写，5 万条约 0.2 s） | — |

App 层（扫描时提特征、索引提交、导出条带）的检查点见 feat/app-layer / feat/render-export 的 CHANGES。

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
  `relaxedConstraints = relaxationCount > 0`；io-cancel 分支后 `relaxationCount` = 4/5/6 级（4 邻域 / 忽略上限 / 忽略邻域）格子数，不含扩 k、分批加深、少量格全库搜索。**结果页提示不看它，只看 `shouldShowShortageNotice`。**
- **打分**：~~λ 默认绝对值 0.005~~ → 已改为相对尺度 `λ_eff = 0.1 × top‑1 中位数`，并加入亮度方差项（评审 M3，见上文）。平局 (score, dist, index) 升序不变。
- **上限**：`cap = max(1, ceil(格子数 / 可用数 × 2))`，可用数取掩码后张数；不开放给用户（`UsageCap.limited/unlimited` 只供测试/内部）。
- **可复现**：遍历顺序 = `Xoshiro256**(seed)` 的 Fisher–Yates 排列；内核结果与线程数/分块无关（测试覆盖）；同种子 + 同素材快照 + 同参数 ⇒ 逐格一致。「换一种拼法」= `MosaicPipeline.reshuffle`，种子 = `MosaicSeed.next(after:)`（SplitMix64 一步，可指定）。
- **子块均值**：默认在**线性光**中求均值再转 OKLab（物理上等于远看的混色，每块只做 1 次转换）；`.perceptual`（逐像素转 OKLab 再平均）可选。
- **网格**：M = `max(1, 短边×N ÷ 长边)` 用**整数**运算（浮点 `3 ÷ 0.05 = 59.999…` 会少算一行，有专门测试）。

### 测试结果（Linux，box：Debian 13 x86_64，8 核，Swift 6.2.4 官方 toolchain）

- `swift test`（debug，含干净构建）：**81 个测试，0 失败**；测试执行 8.0 s，含构建总计 15.9 s。完整输出：`reports/swift-test-linux.txt`。
  套件：Assignment 19、Color 8、ConstrainedMatching 7（QA 移植）、Feature 11、Layout 10、Matching 11、Performance 3、Random 6、SupplyAndReshuffle 6。
- 全规模基准（release，`reports/swift-bench-linux-release.txt`）：top‑32，10,800 格 × 5 万素材 **0.20 s**；完整分配 0.21 s；最坏情况（整张目标图同一颜色、cap = 1）3.3 s，当时 10,672 格逐格全库搜索。（这是 a0102be 的历史数据；当前为 1.19 s，见上文。）
- `MosaicAccelerate` 在 Linux 上 `swift build` 通过（空模块）。
- `xcodegen generate`：在 Linux 上用自编译的 XcodeGen 2.46.0 成功生成 `.xcodeproj`（输出到 /tmp，不入库）；scheme 含 PhotoMosaicTests + `MosaicCoreTests`；`.strings` 进 Resources，`copy_v1.1.md` 不打包。**但没有 Xcode，未做 xcodebuild 编译 / 模拟器测试**。

### 与方案的偏差 / 待架构师确认

1. **回退链**——**已解决**（评审 M1）：`exhaustiveSearchBeforeRelaxing` 开关已删除，逐格全库搜索只在分批加深后剩余 ≤ 256 格时才做；最终链见上文第 4 项。（原问题：素材充足时 262 格误入「忽略上限」。）
2. **极端长图**——**已解决**（产品补充决定 9 方案 A / 评审 M4）：宽高比 > N:1 时格边 = 短边，横图 1 行（竖图 1 列）N 个**正方形**格，长边居中裁掉多余部分；不拉伸、不补边、不拒绝、不提示。例：3000×50 粗档 → cellSize 50、cropRect (500, 0, 2000, 50)，导出 4000×100。`shortEdgeUnderflow` 仍保留，但只作诊断标记，UI 不用。（a0102be 的「长方形取样」已删除。）
3. **导出尺寸**：格边 = ⌊导出长边 ÷ N⌋（如 4000 ÷ 120 → 33 px，长边 3960）。**已由架构师 + 产品经理定为正式规则**（决定 v0.3 01:12）。
4. **子块均值用线性光**——架构师已确认保持不变。
5. ~~λ = 0.005~~ → 相对尺度（M3）。
6. **CI 文件名**：派单写 `ios-ci.yml`（一个文件两个 job），按方案 §11.3 拆成 `linux-core.yml` + `ios.yml`（便于 paths 过滤：纯 MosaicCore 改动不触发 macOS）；TestFlight 只在 `ios.yml` 末尾留注释占位，没建 `testflight.yml`。
7. ~~features.bin、条带切分、叠加混合未做~~ → io-cancel 分支已做。
8. ~~生成取消未做~~ → io-cancel 分支已做（M2）。
9. ~~亮度方差未进打分~~ → io-cancel 分支已做。
10. Swift 版本——**已更新**：CI 钉 `swift:6.3.3-noble`，ios.yml 钉 `macos-26` + Xcode 26.6（Swift 6.3.3），见上文第 12 项。

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
