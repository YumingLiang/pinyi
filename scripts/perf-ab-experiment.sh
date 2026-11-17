#!/usr/bin/env bash
# ⚠️ 临时实验（PR 前删除）：同一 runner 上交错测多个构建变体的 MosaicAppCore E2E 门禁（preview 是第一个用例）。
# 变体：name:commit:mode；mode = full（原样）| genperf（测试 target 只留 GenPerf/）| align（-align-all-functions=6 -align-loops=64）
set -uo pipefail
ws="$PWD"; out="$ws/ab"; mkdir -p "$out"
variants=(
  base:230002d:full p14:72d6109:full pr17:9d35937:full s8d4:8d4ce5a:full s98f:98f8756:full s0a8:0a8bac6:full sa8b:a8b8641:full pr18:0838ac9:full
  base-gp:230002d:genperf pr18-gp:0838ac9:genperf base-al:230002d:align pr18-al:0838ac9:align
)
{
  echo "cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "kernel=$(uname -r)"; swift --version 2>&1 | head -1
} | tee "$out/env.txt"
extra() { case "$1" in align) echo "-Xswiftc -Xllvm -Xswiftc -align-all-functions=6 -Xswiftc -Xllvm -Xswiftc -align-loops=64";; *) echo "";; esac; }
for v in "${variants[@]}"; do
  IFS=: read -r name c mode <<< "$v"
  d="/tmp/ab-$name"; git worktree add -q --detach "$d" "$c"
  if [ "$mode" = genperf ]; then (cd "$d/Packages/MosaicAppCore/Tests/MosaicAppCoreTests" && find . -name '*.swift' ! -path './GenPerf/*' -delete); fi
  t0=$(date +%s)
  MOSAIC_PERF_OUT="$out/first-$name.jsonl" swift test -c release $(extra "$mode") --package-path "$d/Packages/MosaicAppCore" \
    --filter GenerationRunnerE2EPerfGateTests > "$out/build-$name.log" 2>&1 || { echo "build/test $name failed"; grep -m5 error: "$out/build-$name.log"; continue; }
  echo "built $name ($c, $mode): $(( $(date +%s) - t0 )) s, testbin $(stat -c %s "$d/Packages/MosaicAppCore/.build/release/MosaicAppCorePackageTests.xctest") bytes"
done
for round in 1 2 3; do
  n=${#variants[@]}
  for i in $(seq 0 $((n-1))); do
    IFS=: read -r name c mode <<< "${variants[$(( (i + round * 5) % n ))]}"
    [ -f "$out/first-$name.jsonl" ] || continue
    sleep 2
    MOSAIC_PERF_OUT="$out/r$round-$name.jsonl" swift test -c release $(extra "$mode") --skip-build --package-path "/tmp/ab-$name/Packages/MosaicAppCore" \
      --filter GenerationRunnerE2EPerfGateTests > "$out/r$round-$name.log" 2>&1
  done
done
python3 - "$out" "${variants[@]}" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import json, sys, os, statistics as st
out, variants = sys.argv[1], sys.argv[2:]
def load(f):
    d = {}
    for l in open(f):
        l = l.strip()
        if l.startswith('{"metric"'):
            r = json.loads(l); d[r["metric"]] = r["samples"]
    return d
print("### perf A/B（同一 runner，交错 3 轮）\n```\n" + open(os.path.join(out, "env.txt")).read() + "```\n")
ms = ["runner_preview_fetch_medium_1536x1152_2k", "runner_gen_coarse_1536x1152_2k", "runner_gen_medium_1536x1152_2k", "runner_reshuffle_medium_1536x1152_2k", "runner_slowpath_icloud_medium_1536x1152_2k"]
print("| 变体 | commit | 方式 | " + " | ".join(m.replace("runner_", "").replace("_1536x1152_2k", "") for m in ms) + " |")
print("|---|---|---|" + "---:|" * len(ms))
for v in variants:
    name, c, mode = v.split(":")
    agg = {m: [] for m in ms}
    for ph in ("r1", "r2", "r3"):
        f = os.path.join(out, f"{ph}-{name}.jsonl")
        if os.path.exists(f):
            d = load(f)
            for m in ms: agg[m] += d.get(m, [])
    print(f"| {name} | {c} | {mode} | " + " | ".join(f"{st.median(agg[m]):.1f}" if agg[m] else "—" for m in ms) + " |")
PY
