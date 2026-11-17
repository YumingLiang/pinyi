# 生成性能回归门禁（Generation perf regression）

CI：`.github/workflows/linux-core.yml` 的 job `perf-gate`（显示名 **Generation perf regression**）。
ubuntu-latest + `swift:6.3.3-noble`（钉 digest），`swift test -c release --filter PerfGateTests`，**阻断**，无 paths 过滤。

> ⚠️ Linux 上的毫秒数只用来防回归，不能当 iPhone 11 性能退出线（中档 ≤ 10 秒等）的证据。

## 判定规则

- 每个指标：预热 1 次，再测 `MOSAIC_PERF_REPEAT` 次（CI = 5），取**中位数**。
- ubuntu-latest 的机型是混的（11-16 实测 15 次碰到 5 种 CPU：Xeon 8370C、EPYC 7763、EPYC 9V74、Xeon 6975P-C、EPYC 9V45），
  同一指标跨机型的原始中位数能差到 ×2.2，所以**先按机型比**：
  1. CI 在结果文件第一行写 `{"runner_cpu": "...", "nproc": 4}`。
  2. 基线里有该机型（`by_cpu`，≥ 2 份结果才建）→ `比值 = 本次中位数 ÷ 同机型基线`，再除以
     `本次 calib ÷ 同机型基线 calib`，**归一化比值 > 1.20 且 绝对差 > `min_delta_ms` → 失败**
     （`threshold.same_cpu`，`gate_on: normalized`）。
     为什么同机型也要归一化：同型号 CPU 的实例也会整体变慢——11-16 run 44028766958 attempt 6（EPYC 9V74）
     calib ×1.27、所有指标 ×1.27–1.29，代码没变，只按原始比值会误报（当时确实红了一次）。
     依据：同一 job 内 5 次样本极差多数 ≤ 4%、个别到 10%（取中位数后吸收）；同机型跨 run 的中位数偏差 ≤ ×1.03。
  3. 没有该机型 → 对照全局基线（所有结果的中位数），用标定归一化：
     `calib_cpu_scalar` 是固定单线程 CPU 负载（不判定），`speed = 本次 calib ÷ 基线 calib`，
     `归一化比值 = (本次中位数 ÷ 全局基线) ÷ speed`，**归一化比值 > 1.25 且 绝对差 > 10 ms → 失败**（`gate_on = normalized`）。
     依据：最慢的 Xeon 8370C 原始比值到 ×1.25（按原始比值必然误报），归一化后 ≤ ×1.06。
     局限：快机型归一化后偏低（×0.75–0.92），在没有同机型基线的快机型上灵敏度下降——碰到新机型就按下面步骤补基线。
- 可在 `threshold.per_metric` 按指标覆盖 `ratio` / `min_delta_ms` / `same_cpu_ratio`。
- 基线里有、本次没跑出来的指标 → 失败（防止门禁被悄悄删掉）；本次有、基线没有 → 🆕 只显示不判定。
- **同一 job 内自动重测（11-17 起）**：第 1 次测量里超限的指标，只对它们所在的包（按结果文件推出 指标 → 包）
  在同一个 job 里再跑一次 `--filter PerfGateTests`，得到第 2 份结果；**两次样本合并（5 + 5 = 10 个）取中位数，按同一套阈值再判一次**，
  合并后仍超限才失败（第 2 次没跑出来也失败）。第 1 次全部通过就不重测；**缺失的指标直接失败、不重测**。
  calib：第 2 次没有 calib（只重测了 MosaicAppCore）时沿用第 1 次的 calib（同一台 VM）；第 2 次自带 calib 时两次 calib 也合并。
  job summary 里列出 基线 / 第 1 次中位数与比值 / 第 2 次中位数与比值 / 合并中位数与比值 / 结论（失败与否只看合并列）。
  - 依据：PR #18 run 44038111294 attempt 1 里 `runner_gen_coarse` ×1.32、`runner_preview_fetch` ×1.36，是约 1 秒的集中突发
    （preview 后两个样本 + 紧接着的 gen_coarse 整个用例，下一个用例就恢复），calib 在 40 秒后的另一个进程里测、看不到；
    attempt 2 同一 commit gen_coarse ×0.99。min-of-samples 救不了（5 个样本都在突发里）。
  - 为什么合并而不是「两次都超限才失败」：后者在通过/失败上等于取较好的一次，阈值附近的真回归检出率从 q 掉到 q²（QA PR #21 审查 P2-1）；
    合并中位数只判一次，检出率仍约为 q。PR #18 形态（第 1 次 gen_coarse 整段 ×1.32、第 2 次 ×0.99）合并后 ×1.16 → 通过。
  - 代价：第 1 次整段突发特别大（约 ×1.45 以上）时，即使第 2 次干净，合并中位数（≈ 两段的中点）也可能超限 → 失败，需要人工看 summary 或 rerun。
  - 真回归（slowpath +2 s、稳定 ×1.3 以上）两次都在，合并后照样超限；只在第 1 次失败时多花约 10 秒到 1 分钟（只重测相关包、不重编）。
  - 退出码：0 通过 / 1 失败（合并后仍超限、第 2 次缺失或第 1 次缺失）/ 其他 = 脚本或环境错误。脚本：`scripts/perf-gate-run.sh`（测量）+ `scripts/perf-gate.py check --retry-results`（判定）。
  - 每次测量前后打印 `nproc`、`/proc/loadavg`、`/proc/stat` 的 steal（`[perf-diag]` 行，并附在 summary 末尾），**只作诊断，不参与判定**。
- 判定逻辑的自测：`python3 scripts/test_perf_gate.py`（合成数据：只在第 1 次突发 → 过；两次都慢 → 挂；阈值附近、只第 1 次超限但合并后仍超限 → 挂；缺失 → 挂；preview +12 ms → 过、+16 ms → 挂；
  另含 QA 边界用例 `QAPerfGateBoundaries`：刚好等于比值 / min_delta、只第 2 次超限、两个超限一个复现、缺失 + 超限、空重测文件、calib 沿用 / 自带、留痕等）。CI 在测量前先跑。
- job summary 里有表：指标 / 基线 / 本次中位数 / 比值 / 归一化比值 / 本次极差 / 结果。

## 当前门禁指标（`Packages/MosaicCore/Tests/MosaicCoreTests/GenerationPerfGateTests.swift`）

| 指标 | 内容 |
|---|---|
| `gen_fine_2048x1536_50k` | App 入口 `MosaicPipeline.generate(snapshot:)`：2048×1536 目标图取样 → top‑K 匹配 → 约束分配，细档，5 万合成素材（带亮度方差） |
| `gen_medium_2048x1536_50k` | 同上，中档 |
| `sample_fine_2048x1536` | 上面的「取样」阶段单独计时（定位用） |
| `worst_uniform_medium_80x60_cap1_50k` | A‑21 同口径最坏情况：整图同色、cap=1、中档 |
| `overlay_blend_2048x1536` | A‑19 原图叠加 CPU 路径整幅混合（导出像素管线代理；iOS 实际用 CG） |
| `calib_cpu_scalar` | 标定，不判定 |

## App 层端到端门禁指标（`Packages/MosaicAppCore/Tests/MosaicAppCoreTests/GenPerf/GenerationRunnerE2EPerfGateTests.swift`，QA）

固定素材集 v1：2000 张 fake PhotoKit 素材（12% 本机只有低清、8% 仅 iCloud、2% 请求失败），目标图 1536×1152，生产接线（`GenerationRunner.production`）。

| 指标 | 内容 |
|---|---|
| `runner_gen_{coarse,medium,fine}_1536x1152_2k` | 首次生成：每个样本新建 runner，计 `GenerationRunner.run` 全链路（快照 → 匹配 → 分配 → 产物） |
| `runner_reshuffle_{coarse,medium,fine}_1536x1152_2k` | 「换一种拼法」：同一 runner 先 run 一次（不计），再计 reshuffle |
| `runner_preview_fetch_medium_1536x1152_2k` | 结果页预览取缩略图（`ThumbnailPreviewPlan` 128 px，fake PhotoKit） |
| `runner_slowpath_icloud_medium_1536x1152_2k` | 慢 PhotoKit：探测 5 ms / iCloud-only 60 ms，计 run + reshuffle。正确实现不在生成路径上探测（≈ 60 ms，主要是预览取图），b6a1da7 ≈ 2.1 s |

确定性计数（整图匹配/分配遍数、重配轮数、PhotoKit 探测与请求次数、每张最多请求 1 次、不允许网络）在同目录 `GenPerfRegressionTests.swift`，**不需要 `MOSAIC_PERF_GATE`**，随 `Test MosaicAppCore` 普通单测阻断；基线 `perf/gen-perf-counts.json`（66dc745）。

PhotoKit 解码、CoreGraphics 渲染、ImageIO 编码在 Linux 上跑不了，不在本门禁内（需 macOS / 真机另测）。

## 新增门禁用例（QA 端到端用例接入方式）

1. 文件名以 `PerfGateTests.swift` 结尾，放在任意 `Packages/*/Tests/` 下（CI 自动发现所有包）。
2. 用 `MOSAIC_PERF_GATE=1` 守卫（否则 `XCTSkip`），避免平时的 `swift test` 变慢。
3. 每个指标输出一行（并追加到 `MOSAIC_PERF_OUT` 指向的文件，若设置）：
   `[perf] {"metric":"<唯一名>","unit":"ms","samples":[<每次毫秒>,...]}`
   MosaicCoreTests 里可直接用 `PerfGate.measureThrowing("名字") { ... }`（自带预热 + 重复次数 + 输出）；
   其他包照抄 `PerfGate` 这几十行即可。
4. 新指标第一次上 CI 时显示 🆕、不判定；按下面步骤把它加进基线后才开始拦。

## 更新基线

只在**确认是有意的性能变化**（或新增指标）时更新，并在 PR 里写明原因。

```bash
# 1) 拿 ≥ 5 次 CI 运行的结果（同一 commit 重跑 job 即可），artifact 名 perf-results-<attempt>
gh run download <run-id> -n perf-results-1 -D /tmp/p1   # …p2..p5（不同 run 或不同 attempt）
# 2) 每份取中位数，再取中位数的中位数，写回全局基线；同 CPU 型号 ≥ 2 份的再写同机型基线
python3 scripts/perf-gate.py update --results /tmp/p*/perf-results.jsonl --note "原因 + commit"
# 3) 本地自查
python3 scripts/perf-gate.py check --results /tmp/p1/perf-results.jsonl
```

**只新增指标、已有代码没变时**加 `--keep-existing`：已有指标的全局 / 同机型基线保留旧值，
新指标按全局 calib 缩放后写入全局，同机型只补新指标；新数据没覆盖到的同机型条目会被删掉。
这样新一批 runner 偏慢（或偏快）不会把已有基线带偏。

`threshold.per_metric`：`runner_slowpath_*` 的 `min_delta_ms` 为 50（QA，fake PhotoKit sleep 对调度敏感）；`runner_preview_fetch_*` 为 15（11-17）。PR #18 的 0838ac9 在 EPYC 7763 上比基线多约 9 ms。结论：**不是 preview 代码变慢**，而是与测试二进制（布局）有关、
且有运行期成分的机器相关效应；具体机制（静态对齐）**没有证实**。证据（同一 runner 交错 A/B，run 44047313570 / 44049180048，原始数据见各 job 日志 / artifact）：
- 最强的一条：同一份源码只删掉无关测试文件就换档。7763 上 230002d 完整测试 target 31.2 ms、只留 `GenPerf/` 测试 40.1 ms；0838ac9 反过来 38.1 / 31.0（1 台 7763，每个变体 first + 3 轮，取 3 轮共 15 个样本的中位数）。0838ac9 能跑到基线速度，说明 preview 路径没有 ≥ 1 ms 量级的真变慢。
- preview 路径源码（ThumbnailPreviewPlan、GenPerf 夹具、MosaicCore）在 230002d..0838ac9 间未变；编译参数（-O -wmo -g -enable-testing）命令行哈希在各提交间一致；三个包的 Package.swift 相同、零第三方依赖；没有 actions/cache。
- 5 台 7763（run 44047313570，每台 first + 5 轮 + 3 次单跑）：230002d 各轮中位数基本在 30.7–33.0、78ce569 在 36.7–37.8、0838ac9 在 37.3–41.7。Intel 8573C 上（25 个样本中位数）230002d 34.2 / 78ce569 35.4 / 0838ac9 35.2；box（Intel Xeon 8c）三者一样。
- **同一二进制、不重编、交错重跑也会换档**：230002d 在一台上有一轮 40.1；78ce569 有两轮 46.4 / 48.8；0838ac9 有 48.3 / 50.6，且同一台上在 37.3–41.7 之间来回。所以不只是静态布局，还有运行期因素（地址随机化 / 堆对齐 / 缓存别名之类，未定位），同一 job 内重测也不一定能把 preview 拉回基线档。
- 强制对齐（`-Xllvm -align-all-functions=6 -align-loops=64`）后 230002d / 0838ac9 都是 37.2：**只有 1 台 7763 × 3 轮**，不足以证明对齐就是机制。72d6109 / 9d35937 / a8b8641 的 37.4 / 37.3 / 37.1 是**未对齐**的完整构建，和对齐无关。
- 其他机型：Intel 6973P 上同一 230002d 25.0、72d6109 / a8b8641 29.8、0838ac9 25.6，也有两档但与 7763 的快慢不对应；6975P、9V45 平。
min_delta 15 ms 的依据：7763 上同一机器的稳定档位差到约 +9.8 ms（25 个样本的中位数 40.8 vs 31.0）；单轮偶发换档到 46–51 ms 时 15 ms 也盖不住，靠重测或人工 rerun。
重复取图类真回归是 ≥ ×2（+30 ms 以上）仍能检出；代价是 preview 持续变慢 ≤ 15 ms（31 档时约 ×1.48）不报，40 档时余量只剩约 6 ms。
根治建议（QA，后续）：计时里不含 fake 缩略图合成（setup 里预生成），或门禁构建固定对齐后在 7763 上多台 × 多轮验证再重定基线；之后 min_delta 改回 10；
`runner_gen_*` / `runner_reshuffle_*` 为 4（runner 上 6 次：同机型偏差 ≤ 4.5%、归一化后 ≤ ×1.045）。

不要用 box / 本机的结果更新基线（核数和 CPU 与 runner 不同）。
