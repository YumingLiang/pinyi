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

# 4) 未过滤的取图结果要走 isHidden 后置过滤（相簿多选 PR 合并条件；QA #19 第 7 节收紧）：
#    PhotoFetch.allImages / images(in:…) / images(withLocalIdentifiers:…) / keyAssets 的原始结果，除 PhotoFetch.swift 自身外，
#    一律改用 visibleImages(in:) / visibleImages(withLocalIdentifiers:) / visibleObjects / visibleAllImagesCount / visibleKeyAssets。
#    - 不再整文件放行。确实要拿原始 fetch result 的（网格懒加载、素材扫描分批取），在**同一行**写行级标记
#      `// photo-fetch: raw-ok <理由>`，理由不能空；该行必须自己保证后续经过 isHidden 过滤（VisibleIndexMap / visibleObjects）。
#    - 能拦：`PhotoFetch.images( in:` 这类空格变体、`PhotoFetch` 换行后 `.images(in:` 的链式调用、函数引用（不带括号）、按 ID 取图。
#    - 按 ID 取图以 #15 的 PhotoFetch 为准：只有 `PhotoFetch.visibleImages(withLocalIdentifiers:)`（及 `isPickedAssetAvailable`）可用，
#      原始 `images(withLocalIdentifiers:)` 只在 PhotoFetch.swift 内部用；#15 已把全部调用点收口，不再有存量放行。
#    测试：scripts/tests/check-photo-fetch-test.sh（正反例）。
ROOT_APP="${PHOTO_FETCH_APP_DIR:-App}"
# awk：去掉整行注释；以 `.` 开头的续行（换行链式调用）、上一行以 `.` 结尾的，拼回上一行；输出 path:起始行号:拼好的内容。
joined=$(find "$ROOT_APP" -name '*.swift' -not -path "$ROOT_APP/InternalTools/*" -not -name 'PhotoFetch.swift' -print0 2>/dev/null \
  | xargs -0 -r awk '
    function flush() { if (buf != "") print FILENAME_prev ":" start ":" buf; buf = "" }
    FNR == 1 { flush(); FILENAME_prev = FILENAME }
    {
      line = $0
      if (line ~ /^[ \t]*\/\//) next
      if (buf != "" && (line ~ /^[ \t]*\./ || buf ~ /\.[ \t]*$/)) { sub(/^[ \t]+/, "", line); buf = buf line; next }
      flush(); buf = line; start = FNR
    }
    END { flush() }' || true)
raw_re='PhotoFetch[[:space:]]*\.[[:space:]]*(allImages|images|keyAssets)([^A-Za-z0-9_]|$)'
hits=$(printf '%s\n' "$joined" | grep -E "$raw_re" || true)
bad=""
while IFS= read -r h; do
  [ -z "$h" ] && continue
  content=${h#*:*:}
  # 行级标记（理由不能空）
  if printf '%s' "$content" | grep -Eq '//[[:space:]]*photo-fetch:[[:space:]]*raw-ok[[:space:]]+[^[:space:]]'; then continue; fi
  bad+="$h"$'\n'
done <<< "$hits"
if [ -n "$bad" ]; then
  echo "::error::raw PhotoFetch results must go through PhotoFetch.visible* (isHidden post-filter), or carry '// photo-fetch: raw-ok <reason>' on the same line:"
  printf '%s' "$bad"
  fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: all photo fetches go through PhotoFetch; no hidden assets / hidden album."
