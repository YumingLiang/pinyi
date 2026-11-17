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


if __name__ == "__main__":
    unittest.main(verbosity=2)
