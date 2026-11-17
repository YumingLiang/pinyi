#!/usr/bin/env python3
"""scripts/perf-gate.py 判定逻辑的自测（合成数据，只用标准库）。CI 在测量前先跑：python3 scripts/test_perf_gate.py"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts" / "perf-gate.py"
CPU = {"runner_cpu": "Test CPU", "nproc": 4}
PREVIEW = "runner_preview_fetch_medium_1536x1152_2k"

BASELINE = {
    "schema": 1,
    "calibration_metric": "calib_cpu_scalar",
    "threshold": {
        "same_cpu": {"ratio": 1.20, "gate_on": "normalized"},
        "gate_on": "normalized",
        "default": {"ratio": 1.25, "min_delta_ms": 10.0},
        "per_metric": {"runner_gen_coarse_1536x1152_2k": {"min_delta_ms": 4.0}, PREVIEW: {"min_delta_ms": 15.0}},
    },
    "metrics": {
        "calib_cpu_scalar": {"median_ms": 50.0},
        "runner_gen_coarse_1536x1152_2k": {"median_ms": 60.0},
        PREVIEW: {"median_ms": 28.0},
        "gen_fine_2048x1536_50k": {"median_ms": 3000.0},
    },
    "by_cpu": {"Test CPU / 4c": {"runs": 3, "metrics": {
        "calib_cpu_scalar": {"median_ms": 50.0},
        "runner_gen_coarse_1536x1152_2k": {"median_ms": 78.8},
        PREVIEW: {"median_ms": 31.5},
        "gen_fine_2048x1536_50k": {"median_ms": 4000.0},
    }}},
}
NORMAL = {"calib_cpu_scalar": 50.0, "runner_gen_coarse_1536x1152_2k": 78.8, PREVIEW: 31.5, "gen_fine_2048x1536_50k": 4000.0}


class PerfGateJudgement(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.baseline = self.dir / "baseline.json"
        self.baseline.write_text(json.dumps(BASELINE), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def results(self, name, values, drop=()):
        p = self.dir / name
        lines = [json.dumps(CPU)]
        for m, v in values.items():
            if m not in drop:
                lines.append(json.dumps({"metric": m, "unit": "ms", "samples": [v * 0.99, v, v * 1.01, v, v]}))
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def check(self, first, retry=None):
        failed_out = self.dir / "failed.json"
        cmd = [sys.executable, str(GATE), "check", "--baseline", str(self.baseline), "--results", str(first),
               "--failed-out", str(failed_out)]
        if retry:
            cmd += ["--retry-results", str(retry)]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, json.loads(failed_out.read_text()), p.stdout

    def test_clean_first_pass(self):
        rc, failed, _ = self.check(self.results("r1.jsonl", NORMAL))
        self.assertEqual(rc, 0)
        self.assertEqual(failed, {"regressed": [], "missing": []})

    def test_transient_spike_first_pass_only_passes(self):
        spiked = {**NORMAL, "runner_gen_coarse_1536x1152_2k": 104.4}   # PR #18 attempt 1 的 ×1.32
        r1 = self.results("r1.jsonl", spiked)
        rc1, failed, _ = self.check(r1)
        self.assertEqual(rc1, 1)
        self.assertEqual(failed["regressed"], ["runner_gen_coarse_1536x1152_2k"])
        r2 = self.results("r2.jsonl", {"runner_gen_coarse_1536x1152_2k": 78.0, PREVIEW: 31.5})   # 只重测 AppCore，无 calib
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 0, out)
        self.assertIn("重测通过", out)

    def test_regression_in_both_passes_fails(self):
        slow = {**NORMAL, "runner_gen_coarse_1536x1152_2k": 78.8 * 1.35}
        r1 = self.results("r1.jsonl", slow)
        r2 = self.results("r2.jsonl", {"runner_gen_coarse_1536x1152_2k": 78.8 * 1.33})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 1, out)
        self.assertIn("两次都超限", out)

    def test_slowpath_like_big_regression_fails(self):
        slow = {**NORMAL, "gen_fine_2048x1536_50k": 6000.0}   # +2 s
        r1 = self.results("r1.jsonl", slow)
        r2 = self.results("r2.jsonl", {"calib_cpu_scalar": 50.0, "gen_fine_2048x1536_50k": 6000.0})
        rc, _, _ = self.check(r1, r2)
        self.assertEqual(rc, 1)

    def test_regressed_metric_missing_on_retry_fails(self):
        slow = {**NORMAL, "runner_gen_coarse_1536x1152_2k": 110.0}
        r1 = self.results("r1.jsonl", slow)
        r2 = self.results("r2.jsonl", {PREVIEW: 31.5})
        rc, _, _ = self.check(r1, r2)
        self.assertEqual(rc, 1)

    def test_missing_metric_fails_without_retry(self):
        r1 = self.results("r1.jsonl", NORMAL, drop=(PREVIEW,))
        rc, failed, _ = self.check(r1)
        self.assertEqual(rc, 1)
        self.assertEqual(failed["missing"], [PREVIEW])
        self.assertEqual(failed["regressed"], [])

    def test_missing_metric_still_fails_with_clean_retry(self):
        r1 = self.results("r1.jsonl", NORMAL, drop=(PREVIEW,))
        r2 = self.results("r2.jsonl", NORMAL)
        rc, _, _ = self.check(r1, r2)
        self.assertEqual(rc, 1)

    def test_preview_plus_12ms_passes(self):
        both = {**NORMAL, PREVIEW: 31.5 + 12}
        rc, failed, _ = self.check(self.results("r1.jsonl", both))
        self.assertEqual(rc, 0)
        self.assertEqual(failed["regressed"], [])

    def test_preview_plus_16ms_fails_in_both(self):
        both = {**NORMAL, PREVIEW: 31.5 + 16}
        r1 = self.results("r1.jsonl", both)
        rc1, failed, _ = self.check(r1)
        self.assertEqual((rc1, failed["regressed"]), (1, [PREVIEW]))
        rc, _, _ = self.check(r1, self.results("r2.jsonl", {PREVIEW: 31.5 + 16}))
        self.assertEqual(rc, 1)

    def test_repo_baseline_preview_floor_is_15ms(self):
        b = json.loads((ROOT / "perf" / "baseline-linux.json").read_text(encoding="utf-8"))
        self.assertEqual(b["threshold"]["per_metric"][PREVIEW]["min_delta_ms"], 15.0)

    # ---- 合并判定（两次样本合并取中位数再判） ----
    def test_near_threshold_regression_caught_by_pooled_median(self):
        # 真回归刚好在阈值附近：第 1 次 ×1.244 超限，第 2 次 ×1.193 单独不超限；合并 10 个样本中位数 ×1.218 > 1.20 → 失败。
        # 旧规则（两次都超限才失败）会放过它（检出率 q²），合并判定只需一次（≈ q）。
        r1 = self.results("r1", {**NORMAL, "runner_gen_coarse_1536x1152_2k": 98.0})
        r2 = self.results("r2", {"runner_gen_coarse_1536x1152_2k": 94.0})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 1, out)
        self.assertIn("合并中位数超限（第 2 次单独未超限）", out)

    def test_pooled_median_of_spike_and_clean_passes(self):
        # PR #18 形态：第 1 次整段突发 104.4（×1.32），第 2 次 78.0 → 合并中位数 ≈ 91（×1.16）→ 通过。
        r1 = self.results("r1", {**NORMAL, "runner_gen_coarse_1536x1152_2k": 104.4})
        r2 = self.results("r2", {"runner_gen_coarse_1536x1152_2k": 78.0})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 0, out)
        self.assertIn("合并中位数未超限", out)

    def test_huge_first_pass_spike_still_fails_when_pooled(self):
        # 代价（记录在 README）：第 1 次整段 ×1.6 的突发，即使第 2 次干净，合并中位数 ≈ ×1.30 仍超限 → 失败。
        r1 = self.results("r1", {**NORMAL, "runner_gen_coarse_1536x1152_2k": 126.0})
        r2 = self.results("r2", {"runner_gen_coarse_1536x1152_2k": 78.8})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 1, out)

    def test_pooled_uses_both_calibs_when_retry_has_calib(self):
        # 重测含 MosaicCore：两次 calib 也合并。第 2 次整机慢 ×1.3（calib 65、fine 5200）→ 合并后归一化 ≈ 1.15 → 通过。
        r1 = self.results("r1", {**NORMAL, "gen_fine_2048x1536_50k": 5000.0})
        r2 = self.results("r2", {"calib_cpu_scalar": 65.0, "gen_fine_2048x1536_50k": 5200.0})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 0, out)


# ---------------------------------------------------------------------------
# QA 边界用例（PR #21 审查；原 qa/tests/pr21/test_perf_gate_qa.py，QA 编写）。
# 基线与上面同构（同机型 Test CPU / 4c，same_cpu ×1.20 归一化，preview min_delta 15），coarse 同机型基线取 80。
QA_CPU = {"runner_cpu": "Test CPU", "nproc": 4}
COARSE = "runner_gen_coarse_1536x1152_2k"
FINE = "gen_fine_2048x1536_50k"
CALIB = "calib_cpu_scalar"

QA_BASELINE = {
    "schema": 1,
    "calibration_metric": CALIB,
    "threshold": {
        "same_cpu": {"ratio": 1.20, "gate_on": "normalized"},
        "gate_on": "normalized",
        "default": {"ratio": 1.25, "min_delta_ms": 10.0},
        "per_metric": {COARSE: {"min_delta_ms": 4.0}, PREVIEW: {"min_delta_ms": 15.0}},
    },
    "metrics": {CALIB: {"median_ms": 50.0}, COARSE: {"median_ms": 60.0}, PREVIEW: {"median_ms": 28.0},
                FINE: {"median_ms": 3000.0}},
    "by_cpu": {"Test CPU / 4c": {"runs": 3, "metrics": {
        CALIB: {"median_ms": 50.0}, COARSE: {"median_ms": 80.0}, PREVIEW: {"median_ms": 31.5},
        FINE: {"median_ms": 4000.0}}}},
}
QA_NORMAL = {CALIB: 50.0, COARSE: 80.0, PREVIEW: 31.5, FINE: 4000.0}


class QAPerfGateBoundaries(unittest.TestCase):
    """QA 边界用例（PR #21 审查，原 qa/tests/pr21/test_perf_gate_qa.py，QA 编写，原样并入）。
    样本全部取同一个值，中位数精确，便于卡边界；两次样本相同时合并中位数 = 单次中位数。"""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.baseline = self.dir / "baseline.json"
        self.baseline.write_text(json.dumps(QA_BASELINE), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def res(self, name, values, drop=(), cpu=QA_CPU):
        p = self.dir / name
        lines = [json.dumps(cpu)] if cpu else []
        for m, v in values.items():
            if m not in drop:
                lines.append(json.dumps({"metric": m, "unit": "ms", "samples": [v] * 5}))
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def check(self, first, retry=None):
        fo = self.dir / "failed.json"
        cmd = [sys.executable, str(GATE), "check", "--results", str(first), "--baseline", str(self.baseline),
               "--failed-out", str(fo)]
        if retry:
            cmd += ["--retry-results", str(retry)]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, json.loads(fo.read_text()), p.stdout + p.stderr

    # ---- 刚好等于阈值（严格 >，等于算通过） ----
    def test_ratio_exactly_at_limit_passes(self):
        # coarse 同机型 80 × 1.20 = 96.0（Δ16 > 4），比值恰为 1.20
        rc, f, out = self.check(self.res("r1", {**QA_NORMAL, COARSE: 96.0}))
        self.assertEqual((rc, f["regressed"]), (0, []), out)

    def test_ratio_just_over_limit_fails_first_pass(self):
        rc, f, _ = self.check(self.res("r1", {**QA_NORMAL, COARSE: 96.1}))
        self.assertEqual((rc, f["regressed"]), (1, [COARSE]))

    def test_delta_exactly_at_min_delta_passes(self):
        # preview 31.5 + 15.0 = 46.5（×1.476 > 1.20），Δ 恰为 15 → 通过
        rc, f, out = self.check(self.res("r1", {**QA_NORMAL, PREVIEW: 46.5}))
        self.assertEqual((rc, f["regressed"]), (0, []), out)

    def test_delta_just_over_min_delta_fails(self):
        rc, f, _ = self.check(self.res("r1", {**QA_NORMAL, PREVIEW: 46.6}))
        self.assertEqual((rc, f["regressed"]), (1, [PREVIEW]))

    # ---- 组合方式：比值 与 min_delta 是「与」 ----
    def test_and_combination_big_ratio_small_delta_passes(self):
        # preview ×1.44（+14 ms）比值远超 1.20 但 Δ ≤ 15 → 不报（持续变慢也不报）
        r1 = self.res("r1", {**QA_NORMAL, PREVIEW: 45.5})
        rc, f, _ = self.check(r1, self.res("r2", {PREVIEW: 45.5}))
        self.assertEqual(rc, 0)

    def test_and_combination_big_delta_small_ratio_passes(self):
        # fine 4000 → 4700（+700 ms，×1.175 < 1.20）→ 不报
        rc, f, _ = self.check(self.res("r1", {**QA_NORMAL, FINE: 4700.0}))
        self.assertEqual((rc, f["regressed"]), (0, []))

    # ---- 持续真变慢 ----
    def test_sustained_plus_20ms_preview_fails(self):
        r1 = self.res("r1", {**QA_NORMAL, PREVIEW: 51.5})
        rc, _, out = self.check(r1, self.res("r2", {PREVIEW: 51.5}))
        self.assertEqual(rc, 1, out)

    def test_sustained_plus_15ms_preview_is_missed(self):
        """记录灵敏度缺口：+15 ms（×1.48）持续变慢两次都不报。"""
        r1 = self.res("r1", {**QA_NORMAL, PREVIEW: 46.5})
        rc, _, _ = self.check(r1, self.res("r2", {PREVIEW: 46.5}))
        self.assertEqual(rc, 0)

    def test_layout_level_40_leaves_only_6ms_headroom(self):
        """7763 上布局档位 40.5 时，再真变慢 +6.5 ms 就会报（余量约 6 ms）；在 31 档时 +15 ms 都不报——灵敏度随布局档位漂移。"""
        rc, _, _ = self.check(self.res("r1", {**QA_NORMAL, PREVIEW: 47.0}), self.res("r2", {PREVIEW: 47.0}))
        self.assertEqual(rc, 1)

    # ---- 重测组合 ----
    def test_both_fail(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        rc, _, out = self.check(r1, self.res("r2", {COARSE: 110.0}))
        self.assertEqual(rc, 1)
        self.assertIn("两次都超限", out)

    def test_only_second_fails_is_ignored(self):
        """第 1 次没超限的指标不重测；即使第 2 份结果里它超限也不判失败（只判第 1 次超限的指标）。"""
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        r2 = self.res("r2", {COARSE: 80.0, PREVIEW: 60.0})
        rc, _, out = self.check(r1, r2)
        self.assertEqual(rc, 0, out)

    def test_multi_metric_only_one_fails_then_recovers(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        rc, f, _ = self.check(r1)
        self.assertEqual(f["regressed"], [COARSE])
        rc, _, out = self.check(r1, self.res("r2", {COARSE: 81.0, PREVIEW: 31.5}))
        self.assertEqual(rc, 0, out)
        self.assertIn("重测通过", out)

    def test_two_regressed_one_confirmed_fails_with_that_one(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0, PREVIEW: 60.0})
        rc, _, out = self.check(r1, self.res("r2", {COARSE: 80.0, PREVIEW: 60.0}))
        self.assertEqual(rc, 1)
        self.assertIn(f"**失败：{PREVIEW}**", out)

    def test_missing_plus_regressed_first_pass(self):
        rc, f, _ = self.check(self.res("r1", {**QA_NORMAL, COARSE: 110.0}, drop=(FINE,)))
        self.assertEqual((rc, f["missing"], f["regressed"]), (1, [FINE], [COARSE]))

    def test_regressed_metric_missing_on_retry_fails(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        rc, _, _ = self.check(r1, self.res("r2", {PREVIEW: 31.5}))
        self.assertEqual(rc, 1)

    def test_empty_retry_file_fails(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        rc, _, _ = self.check(r1, self.res("r2", {}, cpu=None))
        self.assertEqual(rc, 1)

    # ---- calib ----
    def test_retry_without_calib_reuses_first_calib(self):
        # 第 1 次整机慢 ×1.3（calib 65）：coarse 104 归一化 = 1.0 → 不超限
        rc, f, _ = self.check(self.res("r1", {**QA_NORMAL, CALIB: 65.0, COARSE: 104.0}))
        self.assertEqual(f["regressed"], [])
        # 第 1 次 calib 正常、coarse 超限；第 2 次只测 AppCore（无 calib），沿用 50 → 仍按 50 归一化
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        rc, _, out = self.check(r1, self.res("r2", {COARSE: 104.0}))
        self.assertEqual(rc, 1, out)

    def test_retry_with_own_calib_uses_it(self):
        """重测含 MosaicCore 时第 2 次用自己的 calib：第 2 次整机慢会被 calib 抵消。"""
        r1 = self.res("r1", {**QA_NORMAL, FINE: 5200.0})
        rc, f, _ = self.check(r1)
        self.assertEqual(f["regressed"], [FINE])
        rc, _, out = self.check(r1, self.res("r2", {CALIB: 65.0, FINE: 5200.0}))   # 5200/4000/1.3 = 1.0
        self.assertEqual(rc, 0, out)

    # ---- 日志痕迹 ----
    def test_first_failure_leaves_trace_when_retry_passes(self):
        r1 = self.res("r1", {**QA_NORMAL, COARSE: 110.0})
        _, _, out1 = self.check(r1)
        self.assertIn(f"::warning::[perf] {COARSE} 第 1 次超限", out1)
        self.assertNotIn("::error::", out1)
        _, _, out = self.check(r1, self.res("r2", {COARSE: 80.0}))
        self.assertIn("第 1 次超限、重测通过", out)
        self.assertIn("110.0", out)   # 第 1 次中位数留在 summary 表里

if __name__ == "__main__":
    unittest.main(verbosity=2)
