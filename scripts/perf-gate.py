#!/usr/bin/env python3
"""生成性能回归门禁（CI job「Generation perf regression」）。只用标准库。

结果文件：JSONL，每行 {"metric": "...", "unit": "ms", "samples": [...]}
（测试在 MOSAIC_PERF_GATE=1 时写到 MOSAIC_PERF_OUT；见 perf/README.md）。

用法：
  check  --results R.jsonl [--baseline perf/baseline-linux.json] [--summary FILE]
         取每个指标的中位数，对照基线判定；任一指标回归则退出码 1。
  update --results R1.jsonl R2.jsonl ... [--baseline perf/baseline-linux.json] [--note TEXT]
         用多份结果（建议 ≥ 5 次 CI 运行的 artifact）重算基线：每份取中位数，再取这些中位数的中位数。
         只改 metrics 段，保留 threshold 配置；打印前后对比。
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

DEFAULT_BASELINE = "perf/baseline-linux.json"


def load_results(paths):
    """-> {metric: [median_of_file1, median_of_file2, ...]}，同一文件里同名指标的样本合并。"""
    per_file = []
    for p in paths:
        samples = {}
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("[perf] "):
                line = line[len("[perf] "):]
            if not line.startswith("{"):
                continue
            rec = json.loads(line)
            if rec.get("unit", "ms") != "ms":
                raise SystemExit(f"{p}: 只支持 unit=ms：{rec}")
            samples.setdefault(rec["metric"], []).extend(float(x) for x in rec["samples"])
        per_file.append(samples)
    return per_file


def load_baseline(path):
    p = Path(path)
    if not p.exists():
        return {"schema": 1, "threshold": {}, "metrics": {}}
    return json.loads(p.read_text(encoding="utf-8"))


def threshold_for(base, metric):
    t = {"ratio": 1.25, "min_delta_ms": 20.0}
    t.update(base.get("threshold", {}).get("default", {}))
    t.update(base.get("threshold", {}).get("per_metric", {}).get(metric, {}))
    return t


def check(args):
    base = load_baseline(args.baseline)
    [samples] = load_results([args.results])
    calib = base.get("calibration_metric")
    gate_on = base.get("threshold", {}).get("gate_on", "raw")   # raw | normalized | both
    speed = None
    if calib and calib in samples and calib in base.get("metrics", {}):
        speed = statistics.median(samples[calib]) / base["metrics"][calib]["median_ms"]

    rows, failed = [], []
    for metric in sorted(set(samples) | set(base.get("metrics", {}))):
        b = base.get("metrics", {}).get(metric)
        if metric not in samples:
            rows.append((metric, b and b["median_ms"], None, None, None, "", "❌ 缺失（门禁指标没跑出来）"))
            failed.append(metric)
            continue
        s = samples[metric]
        med = statistics.median(s)
        spread = (max(s) - min(s)) / med * 100 if med > 0 else 0.0
        if b is None:
            rows.append((metric, None, med, None, None, f"{spread:.0f}%", "🆕 无基线（不判定）"))
            continue
        bm = b["median_ms"]
        t = threshold_for(base, metric)
        ratio = med / bm
        norm = ratio / speed if speed else None
        if metric == calib:
            rows.append((metric, bm, med, ratio, None, f"{spread:.0f}%", "ℹ️ 标定（不判定）"))
            continue
        delta_ok = (med - bm) <= t["min_delta_ms"]
        raw_bad = ratio > t["ratio"] and not delta_ok
        norm_bad = norm is not None and norm > t["ratio"] and not delta_ok
        bad = {"raw": raw_bad, "normalized": norm_bad if norm is not None else raw_bad,
               "both": raw_bad and (norm_bad if norm is not None else True)}[gate_on]
        status = f"❌ 回归（> ×{t['ratio']:.2f} 且 > +{t['min_delta_ms']:.0f} ms）" if bad else "✅"
        if bad:
            failed.append(metric)
        rows.append((metric, bm, med, ratio, norm, f"{spread:.0f}%", status))

    def f(v, fmt):
        return "—" if v is None else fmt.format(v)

    out = ["### Generation perf regression（Linux release，中位数 vs `" + args.baseline + "`）", ""]
    out.append(f"判定口径：`{gate_on}`；每指标样本数见结果文件；"
               + (f"本机标定速度 = 基线的 ×{speed:.2f}（>1 表示本 runner 更慢）" if speed else "无标定数据"))
    out.append("")
    out.append("| 指标 | 基线 ms | 本次中位数 ms | 比值 | 标定归一化比值 | 本次极差/中位数 | 结果 |")
    out.append("|---|---:|---:|---:|---:|---:|---|")
    for m, bm, med, ratio, norm, spread, status in rows:
        out.append(f"| `{m}` | {f(bm, '{:.1f}')} | {f(med, '{:.1f}')} | {f(ratio, '×{:.3f}')} | {f(norm, '×{:.3f}')} | {spread or '—'} | {status} |")
    out.append("")
    if failed:
        out.append(f"**失败：{', '.join(failed)}**。确认是有意的变慢后，按 perf/README.md 更新基线。")
    text = "\n".join(out) + "\n"
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    for m in failed:
        print(f"::error::[perf] {m} 回归或缺失，见 job summary")
    return 1 if failed else 0


def update(args):
    base = load_baseline(args.baseline)
    per_file = load_results(args.results)
    metrics = sorted(set().union(*per_file))
    new = {}
    for m in metrics:
        meds = [statistics.median(f[m]) for f in per_file if m in f]
        new[m] = {"median_ms": round(statistics.median(meds), 3),
                  "runs": len(meds),
                  "run_medians_ms": [round(x, 3) for x in meds]}
    old = base.get("metrics", {})
    for m in metrics:
        o = old.get(m, {}).get("median_ms")
        n = new[m]["median_ms"]
        print(f"{m:45s} {('%.1f' % o) if o else '—':>10} -> {n:10.1f}" + (f"  (×{n / o:.3f})" if o else ""))
    dropped = sorted(set(old) - set(new))
    if dropped and not args.allow_drop:
        raise SystemExit(f"这些基线指标在结果里没有，拒绝删除（确认要删加 --allow-drop）：{dropped}")
    base["metrics"] = new
    if args.note:
        base["note"] = args.note
    Path(args.baseline).write_text(json.dumps(base, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已写入 {args.baseline}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--results", required=True)
    c.add_argument("--baseline", default=DEFAULT_BASELINE)
    c.add_argument("--summary")
    u = sub.add_parser("update")
    u.add_argument("--results", nargs="+", required=True)
    u.add_argument("--baseline", default=DEFAULT_BASELINE)
    u.add_argument("--note")
    u.add_argument("--allow-drop", action="store_true")
    a = ap.parse_args()
    return check(a) if a.cmd == "check" else update(a)


if __name__ == "__main__":
    sys.exit(main())
