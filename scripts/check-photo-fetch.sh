#!/usr/bin/env bash
# 隐藏照片守护（photo-picker-v0.1 §5.1、§6.2 第一层）：App 里所有取照片都必须走 App/Adapters/PhotoFetch.swift。
# - App/ 下（InternalTools 除外，PhotoFetch.swift 自身除外）出现 `fetchAssets(` 或 `fetchKeyAssets(` 就失败；
# - 任何地方把 includeHiddenAssets 设成 true 就失败；
# - 任何地方在代码里引用 smartAlbumAllHidden 就失败（PhotoFetch.swift 里只在注释中出现）。
# 只看代码行：整行注释（// 或 ///）不算。CI 的 Linux job 调用；本地也可直接运行。
# 第二层是 AppTests/PhotoFetchTests.swift（macOS job）：断言 PhotoFetch 生成的选项 includeHiddenAssets == false。
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 每条管道末尾 `|| true`：set -o pipefail 下 grep 没匹配会返回 1。
# 去掉整行注释后再匹配：grep 输出是 path:line:content，content 以 // 开头（允许前导空白）的丢掉。
code_only() { grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' || true; }

# 1) fetchAssets( / fetchKeyAssets( 只允许出现在 PhotoFetch.swift
#    （InternalTools 是内部测试工具，不进正式包，设计允许例外）。
#    两条模式分开搜：`fetchAssets(` 不是 `fetchKeyAssets(` 的子串（中间有 Key）。
for api in fetchAssets fetchKeyAssets; do
  matches=$(grep -rEn --include='*.swift' "${api}[[:space:]]*\(" App 2>/dev/null \
    | grep -v '^App/InternalTools/' \
    | grep -v '^App/Adapters/PhotoFetch.swift:' \
    | code_only || true)
  if [ -n "$matches" ]; then
    echo "::error::${api}( must go through PhotoFetch (App/Adapters/PhotoFetch.swift):"
    echo "$matches"
    fail=1
  fi
done

# 2) includeHiddenAssets 不允许设为 true（含 InternalTools）。
matches=$(grep -rEn --include='*.swift' 'includeHiddenAssets[[:space:]]*=[[:space:]]*true' App AppTests 2>/dev/null | code_only || true)
if [ -n "$matches" ]; then
  echo "::error::includeHiddenAssets = true is forbidden:"
  echo "$matches"
  fail=1
fi

# 3) 不允许在代码里引用「已隐藏」智能相簿（InternalTools 也不行；PhotoFetch.swift 只在注释里提到）。
matches=$(grep -rn --include='*.swift' 'smartAlbumAllHidden' App 2>/dev/null | code_only || true)
if [ -n "$matches" ]; then
  echo "::error::smartAlbumAllHidden must never be referenced in code:"
  echo "$matches"
  fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: all photo fetches go through PhotoFetch; no hidden assets / hidden album."
