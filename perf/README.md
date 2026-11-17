# 生成性能回归门禁（Generation perf regression）

CI：`.github/workflows/linux-core.yml` 的 job `perf-gate`（显示名 **Generation perf regression**）。
ubuntu-latest + `swift:6.3.3-noble`（钉 digest），`swift test -c release --filter PerfGateTests`，**阻断**，无 paths 过滤。

> ⚠️ Linux 上的毫秒数只用来防回归，不能当 iPhone 11 性能退出线（中档 ≤ 10 秒等）的证据。

## 判定规则

- 每个指标：预热 1 次，再测 `MOSAIC_PERF_REPEAT` 次（CI = 5），取**中位数**。
- `calib_cpu_scalar` 是固定的单线程 CPU 负载，不判定，只用来算本 runner 的速度系数
  `speed = 本次 calib 中位数 ÷ 基线 calib`（>1 = 这台 runner 更慢）。
- 对照 `perf/baseline-linux.json`：`比值 = 本次中位数 ÷ 基线`，`归一化比值 = 比值 ÷ speed`。
  **当前口径 `gate_on = normalized`：归一化比值 > `ratio`（1.25）且 本次中位数 − 基线 > `min_delta_ms`（10 ms）→ 失败。**
  可选 `raw`（只看原始比值）/ `both`（两者都超才失败）；可在 `threshold.per_metric` 按指标覆盖。
- 为什么用归一化：ubuntu-latest 的机型是混的（11-16 实测 5 次：Xeon 8370C、EPYC 7763 ×3、Xeon 6975P-C），
  原始中位数跨机型极差 25–46%，最慢机型比中位数高到 ×1.16，离 ×1.25 只剩 8%；
  归一化后各门禁指标 max/中位数 ≤ ×1.03，×1.25 留 ≥ 20% 余量。同一 job 内 5 次样本极差 ≤ 2%，所以 5 次足够。
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
# 2) 每份取中位数，再取中位数的中位数，写回基线
python3 scripts/perf-gate.py update --results /tmp/p*/perf-results.jsonl --note "原因 + commit"
# 3) 本地自查
python3 scripts/perf-gate.py check --results /tmp/p1/perf-results.jsonl
```

不要用 box / 本机的结果更新基线（核数和 CPU 与 runner 不同）。
