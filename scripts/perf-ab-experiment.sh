#!/usr/bin/env bash
# ⚠️ 临时实验（PR 前删除）：同一 runner 上对比几个 commit 的 MosaicAppCore E2E 门禁（preview 是第一个用例）。
set -uo pipefail
ws="$PWD"; out="$ws/ab"; mkdir -p "$out"
commits=(230002d 0838ac9 78ce569)
diag() { echo "[ab-diag] $1 nproc=$(nproc) loadavg=\"$(cat /proc/loadavg)\" steal=$(awk '/^cpu /{print $9}' /proc/stat)"; }
{
  echo "cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "kernel=$(uname -r)"; echo "thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  echo "mem=$(awk '/MemTotal|MemAvailable/{printf "%s %s ", $1, $2}' /proc/meminfo)"
  df -T "$ws" /tmp | tail -n +2 | awk '{print "fs " $7 " " $2}'
  swift --version 2>&1 | head -1
} | tee "$out/env.txt"
for c in "${commits[@]}"; do
  git worktree add -q --detach "/tmp/ab-$c" "$c"
done
# 1) 构建（逐个），记录 swiftc 命令行（去掉路径后求哈希）、测试二进制大小；构建完立刻测一次（与 CI 同：build 后第一个用例）
for c in "${commits[@]}"; do
  p="/tmp/ab-$c/Packages/MosaicAppCore"
  t0=$(date +%s)
  diag "first-$c before"
  # 与 CI 完全相同：swift test -c release（会加 -enable-testing），build 完立刻跑；-v 记录编译命令
  MOSAIC_PERF_OUT="$out/first-$c.jsonl" swift test -c release -v --package-path "$p" --filter GenerationRunnerE2EPerfGateTests > "$out/build-$c.log" 2>&1 || { echo "build/test $c failed"; grep -m5 error: "$out/build-$c.log"; exit 2; }
  diag "first-$c after"
  echo "build $c: $(( $(date +%s) - t0 )) s"
  grep -- '^/.*swiftc -module-name MosaicAppCore ' "$out/build-$c.log" | head -1 | sed "s#/tmp/ab-$c#@#g" | tr ' ' '\n' \
    | grep -v '/' | grep -v '\.swift$' | sort -u | tr '\n' ' ' > "$out/flags-$c.txt"
  echo "flags $c: md5=$(md5sum < "$out/flags-$c.txt" | cut -c1-8) $(tr ' ' '\n' < "$out/flags-$c.txt" | grep -E '^-(O|g|wmo|whole-module|enable-testing|cross-module|enable-default-cmo|num-threads|j)' | tr '\n' ' ')"
  bin=$(ls -d "$p"/.build/release/MosaicAppCorePackageTests.xctest 2>/dev/null || true)
  echo "testbin $c: $(stat -c %s "$bin" 2>/dev/null) bytes"
done
# 2) 交错重测：5 轮，每轮顺序轮换；每次先 sleep 3 s
for round in 1 2 3 4 5; do
  n=${#commits[@]}
  for i in $(seq 0 $((n-1))); do
    c=${commits[$(( (i + round) % n ))]}
    p="/tmp/ab-$c/Packages/MosaicAppCore"
    sleep 3
    MOSAIC_PERF_OUT="$out/r$round-$c.jsonl" swift test -c release --skip-build --package-path "$p" --filter GenerationRunnerE2EPerfGateTests > "$out/r$round-$c.log" 2>&1
    echo "round $round $c: $(grep -o '"metric":"runner_preview_fetch[^}]*' "$out/r$round-$c.jsonl" | head -1)"
  done
done
# 3) 只跑 preview 一个用例（排除"第一个用例"效应），每个 commit 3 次
for k in 1 2 3; do for c in "${commits[@]}"; do
  p="/tmp/ab-$c/Packages/MosaicAppCore"
  MOSAIC_PERF_OUT="$out/solo$k-$c.jsonl" swift test -c release --skip-build --package-path "$p" --filter 'GenerationRunnerE2EPerfGateTests.testPreviewFetchMedium' > /dev/null 2>&1
done; done
python3 - "$out" "${commits[@]}" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import json, sys, glob, os, statistics as st
out, commits = sys.argv[1], sys.argv[2:]
def load(f):
    d = {}
    for l in open(f):
        l = l.strip()
        if l.startswith('{"metric"'):
            r = json.loads(l); d[r["metric"]] = r["samples"]
    return d
print("### perf A/B（同一 runner）\n")
print("```"); print(open(os.path.join(out, "env.txt")).read()); print("```\n")
ms = ["runner_preview_fetch_medium_1536x1152_2k", "runner_gen_coarse_1536x1152_2k", "runner_gen_medium_1536x1152_2k", "runner_reshuffle_medium_1536x1152_2k"]
print("| 阶段 | commit | " + " | ".join(m.replace("runner_", "").replace("_1536x1152_2k", "") for m in ms) + " | preview 样本 |")
print("|---|---|" + "---:|" * len(ms) + "---|")
phases = ["first"] + [f"r{i}" for i in range(1, 6)] + [f"solo{i}" for i in range(1, 4)]
for ph in phases:
    for c in commits:
        f = os.path.join(out, f"{ph}-{c}.jsonl")
        if not os.path.exists(f): continue
        d = load(f)
        cells = [f"{st.median(d[m]):.1f}" if m in d else "—" for m in ms]
        pv = d.get(ms[0], [])
        print(f"| {ph} | {c} | " + " | ".join(cells) + f" | {[round(x,1) for x in pv]} |")
print()
for c in commits:
    allp = []
    for ph in phases[1:6]:
        f = os.path.join(out, f"{ph}-{c}.jsonl")
        if os.path.exists(f): allp += load(f).get(ms[0], [])
    if allp: print(f"- {c}: 交错 5 轮 preview 全部样本中位数 {st.median(allp):.2f} ms（n={len(allp)}，min {min(allp):.1f}，max {max(allp):.1f}）")
PY
