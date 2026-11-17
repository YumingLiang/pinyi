#!/usr/bin/env bash
# 跑一遍 *PerfGateTests（release），供 CI job「Generation perf regression」用。
# 用法：scripts/perf-gate-run.sh <第几次> <结果.jsonl> <指标→包.json> [包目录 ...]
#   不给包目录 = 自动发现所有含 *PerfGateTests.swift 的 Packages/*；重测时只传第 1 次超限指标所在的包。
# 结果文件第一行是 {"runner_cpu", "nproc"}，其后是各包测试写出的 [perf] 行（见 perf/README.md）。
# 测量前后打印 nproc、/proc/loadavg、/proc/stat 的 steal（只作诊断，不参与判定）。
set -euo pipefail
pass="$1"; out="$2"; map="$3"; shift 3
ws="${GITHUB_WORKSPACE:-$PWD}"
log="$ws/perf-log.txt"

diag() {
  local when="$1" steal
  steal=$(awk '/^cpu /{print $9}' /proc/stat)
  echo "[perf-diag] pass=$pass $when nproc=$(nproc) loadavg=\"$(cat /proc/loadavg)\" steal_ticks=$steal" | tee -a "$log"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- 诊断（第 $pass 次 $when）：nproc=$(nproc)，loadavg=\`$(cat /proc/loadavg)\`，/proc/stat steal=$steal ticks" >> "$ws/perf-diag.md"
  fi
}

pkgs=("$@")
if [ ${#pkgs[@]} -eq 0 ]; then
  for pkg in Packages/*/; do
    pkg="${pkg%/}"
    # 不用 find | grep -q：pipefail 下 find 收到 SIGPIPE 会被当成「没找到」（同 ios.yml 41dc45f 的教训）。
    if [ -d "$pkg/Tests" ] && [ -n "$(find "$pkg/Tests" -name '*PerfGateTests.swift' -print -quit)" ]; then
      pkgs+=("$pkg")
    fi
  done
fi
[ ${#pkgs[@]} -gt 0 ] || { echo "::error::没找到任何 *PerfGateTests.swift"; exit 1; }

# 第一行记 runner 的 CPU 型号：ubuntu-latest 机型是混的，脚本按同机型基线比（没有才退回全局归一化）。
python3 -c 'import json,os,re; m=re.search(r"model name\s*:\s*(.*)", open("/proc/cpuinfo").read()); print(json.dumps({"runner_cpu": m.group(1).strip() if m else "", "nproc": os.cpu_count()}))' > "$out"
echo '{}' > "$map"

diag before
for pkg in "${pkgs[@]}"; do
  part="$ws/perf-part-$pass-$(basename "$pkg").jsonl"
  : > "$part"
  echo "::group::第 $pass 次 $pkg"
  (cd "$pkg" && MOSAIC_PERF_OUT="$part" swift test -c release --filter PerfGateTests 2>&1 | tee -a "$log")
  echo "::endgroup::"
  cat "$part" >> "$out"
  python3 - "$map" "$part" "$pkg" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for line in open(sys.argv[2]):
    line = line.strip()
    if line.startswith("{"):
        m[json.loads(line)["metric"]] = sys.argv[3]
json.dump(m, open(sys.argv[1], "w"), ensure_ascii=False)
PY
done
diag after
cat "$out"
