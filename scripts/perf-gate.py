#!/usr/bin/env python3
"""生成性能回归门禁（CI job「Generation perf regression」）。只用标准库。

结果文件：JSONL，每行 {"metric": "...", "unit": "ms", "samples": [...]}
（测试在 MOSAIC_PERF_GATE=1 时写到 MOSAIC_PERF_OUT；见 perf/README.md）。

用法：
  check  --results R.jsonl [--baseline perf/baseline-linux.json] [--summary FILE]
         取每个指标的中位数，对照基线判定；任一指标回归则退出码 1。
  update --results R1.jsonl R2.jsonl ... [--baseline perf/baseline-linux.json] [--note TEXT]
         用多份结果（建议 ≥ 5 次 CI 运行的 artifact）重算基线：每份取中位数，再取这些中位数的中位数。
         另按 runner CPU 型号分组，≥ --min-runs 份的型号写同机型基线（by_cpu）。
         只改 metrics / by_cpu，保留 threshold 配置；打印前后对比。
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

DEFAULT_BASELINE = "perf/baseline-linux.json"


def load_results(paths):
    """-> [(meta, {metric: [samples...]})]，每个文件一项；同一文件里同名指标的样本合并。
    meta 来自 CI 写入的 {"runner_cpu": "...", "nproc": N} 行。"""
    per_file = []
    for p in paths:
        samples, meta = {}, {}
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("[perf] "):
                line = line[len("[perf] "):]
            if not line.startswith("{"):
                continue
            rec = json.loads(line)
            if "runner_cpu" in rec:
                meta.update(rec)
                continue
            if rec.get("unit", "ms") != "ms":
                raise SystemExit(f"{p}: 只支持 unit=ms：{rec}")
            samples.setdefault(rec["metric"], []).extend(float(x) for x in rec["samples"])
        per_file.append((meta, samples))
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


def cpu_key(meta):
    cpu = (meta.get("runner_cpu") or "").strip()
    return f"{cpu} / {meta['nproc']}c" if cpu and meta.get("nproc") else cpu


def check(args):
    base = load_baseline(args.baseline)
    [(meta, samples)] = load_results([args.results])
    thr = base.get("threshold", {})
    calib = base.get("calibration_metric")
    gate_on = thr.get("gate_on", "raw")   # 无同机型基线时的口径：raw | normalized | both
    cpu = cpu_key(meta)
    same = base.get("by_cpu", {}).get(cpu, {}).get("metrics", {}) if cpu else {}
    same_ratio = thr.get("same_cpu", {}).get("ratio", 1.20)
    same_gate = thr.get("same_cpu", {}).get("gate_on", "normalized")   # normalized | raw
    same_speed = None
    if calib and calib in samples and calib in same:
        same_speed = statistics.median(samples[calib]) / same[calib]["median_ms"]
    speed = None
    if calib and calib in samples and calib in base.get("metrics", {}):
        speed = statistics.median(samples[calib]) / base["metrics"][calib]["median_ms"]

    rows, failed = [], []
    for metric in sorted(set(samples) | set(base.get("metrics", {}))):
        b = base.get("metrics", {}).get(metric)
        if metric not in samples:
            rows.append((metric, "", b and b["median_ms"], None, None, None, "", "❌ 缺失（门禁指标没跑出来）"))
            failed.append(metric)
            continue
        s = samples[metric]
        med = statistics.median(s)
        spread = (max(s) - min(s)) / med * 100 if med > 0 else 0.0
        if b is None and metric not in same:
            rows.append((metric, "", None, med, None, None, f"{spread:.0f}%", "🆕 无基线（不判定）"))
            continue
        t = threshold_for(base, metric)
        if metric in same:
            bm = same[metric]["median_ms"]
            ratio = med / bm
            limit = t.get("same_cpu_ratio", same_ratio)
            # 同型号 CPU 的实例也会整体慢（11-16 run 44028766958 attempt 6：EPYC 9V74 calib ×1.27、所有指标 ×1.27–1.29，
            # 代码没变）。所以同机型也用同机型 calib 归一化；纯「机器慢」会被 calib 抵消，代码变慢不影响 calib。
            norm = ratio / same_speed if same_speed else None
            ref = "同机型" + ("（归一化）" if same_gate == "normalized" and norm is not None else "")
            over = (norm if same_gate == "normalized" and norm is not None else ratio) > limit
            bad = over and (med - bm) > t["min_delta_ms"]
        else:
            bm = b["median_ms"]
            ratio = med / bm
            limit = t["ratio"]
            norm = ratio / speed if speed else None
            ref = "全局" + ("（归一化）" if gate_on != "raw" and norm is not None else "")
            delta_ok = (med - bm) <= t["min_delta_ms"]
            raw_bad = ratio > limit and not delta_ok
            norm_bad = norm is not None and norm > limit and not delta_ok
            bad = {"raw": raw_bad, "normalized": norm_bad if norm is not None else raw_bad,
                   "both": raw_bad and (norm_bad if norm is not None else True)}[gate_on]
        if metric == calib:
            rows.append((metric, ref, bm, med, ratio, None, f"{spread:.0f}%", "ℹ️ 标定（不判定）"))
            continue
        status = f"❌ 回归（> ×{limit:.2f} 且 > +{t['min_delta_ms']:.0f} ms）" if bad else f"✅（限 ×{limit:.2f}）"
        if bad:
            failed.append(metric)
        rows.append((metric, ref, bm, med, ratio, norm, f"{spread:.0f}%", status))

    def f(v, fmt):
        return "—" if v is None else fmt.format(v)

    out = ["### Generation perf regression（Linux release，中位数 vs `" + args.baseline + "`）", ""]
    out.append(f"runner：`{cpu or '未知'}`；" + ((f"有同机型基线，按同机型比（口径 `{same_gate}`" + (f"，本机 calib = 同机型基线的 ×{same_speed:.2f}" if same_speed else "") + "）。") if same else
               f"无同机型基线，按全局基线、口径 `{gate_on}`。")
               + (f" 标定速度 = 全局基线的 ×{speed:.2f}（>1 表示本 runner 更慢）。" if speed else ""))
    out.append("")
    out.append("| 指标 | 对照 | 基线 ms | 本次中位数 ms | 比值 | 归一化比值 | 本次极差/中位数 | 结果 |")
    out.append("|---|---|---:|---:|---:|---:|---:|---|")
    for m, ref, bm, med, ratio, norm, spread, status in rows:
        out.append(f"| `{m}` | {ref or '—'} | {f(bm, '{:.1f}')} | {f(med, '{:.1f}')} | {f(ratio, '×{:.3f}')} | {f(norm, '×{:.3f}')} | {spread or '—'} | {status} |")
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


def medians_of(files):
    metrics = sorted(set().union(*[s for _, s in files]))
    out = {}
    for m in metrics:
        meds = [statistics.median(s[m]) for _, s in files if m in s]
        out[m] = {"median_ms": round(statistics.median(meds), 3), "runs": len(meds),
                  "run_medians_ms": [round(x, 3) for x in meds]}
    return out


def scaled_medians(files, calib, calib_ref):
    """把每份结果按本次 calib 缩放到 calib_ref 的机器速度后取中位数（新指标并入已有全局基线时用，口径与全局 calib 一致）。"""
    metrics = sorted(set().union(*[s for _, s in files]))
    out = {}
    for m in metrics:
        vals = [statistics.median(s[m]) * calib_ref / statistics.median(s[calib]) for _, s in files if m in s and calib in s]
        if vals:
            out[m] = {"median_ms": round(statistics.median(vals), 3), "runs": len(vals), "scaled_to_global_calib": True,
                      "run_medians_ms": [round(statistics.median(s[m]), 3) for _, s in files if m in s and calib in s]}
    return out


def update_keep_existing(args, base, per_file):
    """只新增指标：已有指标（全局与同机型）一律保留旧值，新指标按全局 calib 缩放后写入全局，
    同机型（≥ --min-runs 份）只补新指标；新数据没覆盖到的同机型条目删掉。"""
    calib = base.get("calibration_metric")
    old = base.get("metrics", {})
    if not calib or calib not in old:
        raise SystemExit("--keep-existing 需要全局基线里已有 calibration_metric")
    added = {m: v for m, v in scaled_medians(per_file, calib, old[calib]["median_ms"]).items() if m not in old}
    for m, v in added.items():
        print(f"新增全局 {m:45s} {v['median_ms']:10.1f}（按全局 calib 缩放）")
    base["metrics"] = {**old, **added}
    groups = {}
    for meta, s in per_file:
        k = cpu_key(meta)
        if k:
            groups.setdefault(k, []).append((meta, s))
    by_cpu = {}
    for k, files in sorted(groups.items()):
        if len(files) < args.min_runs:
            print(f"跳过同机型：{k}（{len(files)} 份 < {args.min_runs}）")
            continue
        fresh = medians_of(files)
        kept = base.get("by_cpu", {}).get(k, {}).get("metrics", {})
        by_cpu[k] = {"runs": len(files), "metrics": {**fresh, **kept}}
        print(f"同机型：{k}（{len(files)} 份；保留旧指标 {len(kept)} 个，新增 {len(set(fresh) - set(kept))} 个）")
    dropped = sorted(set(base.get("by_cpu", {})) - set(by_cpu))
    if dropped:
        print(f"删除新数据未覆盖的同机型条目：{dropped}")
    base["by_cpu"] = by_cpu
    return base


def update(args):
    base = load_baseline(args.baseline)
    per_file = load_results(args.results)
    if args.keep_existing:
        base = update_keep_existing(args, base, per_file)
        if args.note:
            base["note"] = args.note
        Path(args.baseline).write_text(json.dumps(base, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"已写入 {args.baseline}")
        return 0
    new = medians_of(per_file)
    old = base.get("metrics", {})
    for m, v in new.items():
        o = old.get(m, {}).get("median_ms")
        n = v["median_ms"]
        print(f"{m:45s} {('%.1f' % o) if o else '—':>10} -> {n:10.1f}" + (f"  (×{n / o:.3f})" if o else ""))
    dropped = sorted(set(old) - set(new))
    if dropped and not args.allow_drop:
        raise SystemExit(f"这些基线指标在结果里没有，拒绝删除（确认要删加 --allow-drop）：{dropped}")
    base["metrics"] = new
    # 同机型基线：同一 CPU 型号至少 min_runs 份结果才建（GitHub ubuntu-latest 机型是混的）。
    groups = {}
    for meta, s in per_file:
        k = cpu_key(meta)
        if k:
            groups.setdefault(k, []).append((meta, s))
    by_cpu = {}
    for k, files in sorted(groups.items()):
        if len(files) >= args.min_runs:
            by_cpu[k] = {"runs": len(files), "metrics": medians_of(files)}
            print(f"同机型基线：{k}（{len(files)} 份）")
        else:
            print(f"跳过同机型基线：{k}（只有 {len(files)} 份 < {args.min_runs}，该机型按全局归一化判定）")
    base["by_cpu"] = by_cpu
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
    u.add_argument("--keep-existing", action="store_true",
                   help="已有指标保留旧基线、只新增指标（代码没变、只是换了一批 runner 时用，避免机型组合变化把基线抬高）")
    u.add_argument("--min-runs", type=int, default=2, help="建同机型基线所需的最少结果份数")
    a = ap.parse_args()
    return check(a) if a.cmd == "check" else update(a)


if __name__ == "__main__":
    sys.exit(main())
