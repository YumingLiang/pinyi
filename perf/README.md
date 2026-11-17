# 生成性能回归门禁（Generation perf regression）

CI：`.github/workflows/linux-core.yml` 的 job `perf-gate`（显示名 **Generation perf regression**）。
ubuntu-latest + `swift:6.3.3-noble`（钉 digest），`swift test -c release --filter PerfGateTests`，**阻断**，无 paths 过滤。

> ⚠️ Linux 上的毫秒数只用来防回归，不能当 iPhone 11 性能退出线（中档 ≤ 10 秒等）的证据。

## 判定规则

- 每个指标：预热 1 次，再测 `MOSAIC_PERF_REPEAT` 次（CI = 5），取**中位数**。
- ubuntu-latest 的机型是混的（11-16 实测 15 次碰到 5 种 CPU：Xeon 8370C、EPYC 7763、EPYC 9V74、Xeon 6975P-C、EPYC 9V45），
  同一指标跨机型的原始中位数能差到 ×2.2，所以**先按机型比**：
  1. CI 在结果文件第一行写 `{"runner_cpu": "...", "nproc": 4}`。
  2. 基线里有该机型（`by_cpu`，≥ 2 份结果才建）→ `比值 = 本次中位数 ÷ 同机型基线`，
     **比值 > 1.20 且 绝对差 > 10 ms → 失败**（`threshold.same_cpu.ratio`）。
     依据：同一 job 内 5 次样本极差多数 ≤ 4%、个别到 10%（取中位数后吸收）；同机型跨 run 的中位数偏差 ≤ ×1.03。
  3. 没有该机型 → 对照全局基线（所有结果的中位数），用标定归一化：
     `calib_cpu_scalar` 是固定单线程 CPU 负载（不判定），`speed = 本次 calib ÷ 基线 calib`，
     `归一化比值 = (本次中位数 ÷ 全局基线) ÷ speed`，**归一化比值 > 1.25 且 绝对差 > 10 ms → 失败**（`gate_on = normalized`）。
     依据：最慢的 Xeon 8370C 原始比值到 ×1.25（按原始比值必然误报），归一化后 ≤ ×1.06。
     局限：快机型归一化后偏低（×0.75–0.92），在没有同机型基线的快机型上灵敏度下降——碰到新机型就按下面步骤补基线。
- 可在 `threshold.per_metric` 按指标覆盖 `ratio` / `min_delta_ms` / `same_cpu_ratio`。
- 基线里有、本次没跑出来的指标 → 失败（防止门禁被悄悄删掉）；本次有、基线没有 → 🆕 只显示不判定。
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

不要用 box / 本机的结果更新基线（核数和 CPU 与 runner 不同）。
