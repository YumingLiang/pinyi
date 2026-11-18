#!/usr/bin/env bash
# check-photo-fetch.sh 规则 5 的正反例（架构师 11-17 第 6 条）：InternalTools 豁免（TestAlbumWriter 的 fetchAssets 等）
# 只在这些文件确实只进内测包时成立。每个用例在临时目录搭最小仓库（App/、project.yml、Config/），断言退出码。
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/check-photo-fetch.sh"
pass=0; failn=0

GOOD_YML=$'name: X\nsettings:\n  configs:\n    Debug:\n      SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) DEBUG INTERNAL_TOOLS\n    Release:\n      APP_DISPLAY_NAME: X\n    Internal:\n      SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) INTERNAL_TOOLS\ntargets:\n  PhotoMosaic:\n    sources:\n      - path: App\n  PhotoMosaicTests:\n    sources:\n      - path: AppTests'
WRITER=$'#if INTERNAL_TOOLS\nimport Photos\nstruct TestAlbumWriter {\n    func f() { _ = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }\n}\n#endif'

# 用法：run_case <名字> <期望 0|1> [路径 内容]...（不给 project.yml 时用 GOOD_YML；给 App/InternalTools/TestAlbumWriter.swift 以外的会追加）
run_case() {
  local name=$1 expect=$2; shift 2
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts" "$tmp/App/Adapters" "$tmp/App/InternalTools" "$tmp/Config"
  cp "$script" "$tmp/scripts/check-photo-fetch.sh"
  printf 'enum PhotoFetch { static func allImages() {} }\n' > "$tmp/App/Adapters/PhotoFetch.swift"
  printf '%s\n' "$GOOD_YML" > "$tmp/project.yml"
  printf '%s\n' "$WRITER" > "$tmp/App/InternalTools/TestAlbumWriter.swift"
  printf 'SWIFT_VERSION = 5.10\n' > "$tmp/Config/Base.xcconfig"
  while [ $# -ge 2 ]; do
    mkdir -p "$tmp/$(dirname "$1")"
    printf '%s\n' "$2" > "$tmp/$1"
    shift 2
  done
  local out rc
  out=$(cd "$tmp" && bash scripts/check-photo-fetch.sh 2>&1); rc=$?
  [ "$rc" -ne 0 ] && rc=1
  if [ "$rc" -eq "$expect" ]; then pass=$((pass + 1)); else
    failn=$((failn + 1)); echo "FAIL: $name (expected $expect, got $rc)"; echo "$out" | sed 's/^/    /'
  fi
  rm -rf "$tmp"
}

W=App/InternalTools/TestAlbumWriter.swift
# ---- 正例 ----
run_case "现状：包在 #if INTERNAL_TOOLS 里，只在 Debug / Internal 定义" 0
run_case "文件头注释 / 空行在 #if 之前" 0 $W $'// 内部工具\n\n'"$WRITER"$'\n'
run_case "主 App 在 #if INTERNAL_TOOLS 里引用" 0 App/Views/Settings.swift $'struct S {\n#if INTERNAL_TOOLS\n    let w = TestAlbumWriter()\n#endif\n}'
run_case "注释里提到 TestAlbumWriter" 0 App/Views/Settings.swift '// TestAlbumWriter 只在内测包'

# ---- 反例 ----
run_case "TestAlbumWriter 没有 #if INTERNAL_TOOLS" 1 $W $'import Photos\nstruct TestAlbumWriter {\n    func f() { _ = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }\n}'
run_case "#if 条件换成 DEBUG" 1 $W $'#if DEBUG\nstruct TestAlbumWriter {}\n#endif'
run_case "#endif 之后还有代码" 1 $W "$WRITER"$'\nstruct Leak {}'
run_case "#if 之前还有代码" 1 $W $'import Photos\n'"$WRITER"
run_case "InternalTools 新文件没包" 1 App/InternalTools/Other.swift 'struct Other {}'
run_case "主 App 在 #if 外引用 TestAlbumWriter" 1 App/Views/Settings.swift 'struct S { let w = TestAlbumWriter() }'
run_case "#if INTERNAL_TOOLS 已结束后引用" 1 App/Views/Settings.swift $'#if INTERNAL_TOOLS\nlet a = 1\n#endif\nlet w = TestAlbumWriter()'
run_case "AppTests 引用 TestAlbumWriter" 1 AppTests/T.swift 'let w = TestAlbumWriter()'
run_case "Release 配置加了 INTERNAL_TOOLS" 1 project.yml "${GOOD_YML/APP_DISPLAY_NAME: X/SWIFT_ACTIVE_COMPILATION_CONDITIONS: \$(inherited) INTERNAL_TOOLS}"
run_case "target 级 settings 加了 INTERNAL_TOOLS" 1 project.yml "$GOOD_YML"$'\n    settings:\n      base:\n        SWIFT_ACTIVE_COMPILATION_CONDITIONS: INTERNAL_TOOLS'
run_case "测试 target 收进 InternalTools 源码" 1 project.yml "$GOOD_YML"$'\n      - path: App/InternalTools'
run_case "xcconfig 定义 INTERNAL_TOOLS" 1 Config/Base.xcconfig 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) INTERNAL_TOOLS'

echo "check-photo-fetch internal tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
