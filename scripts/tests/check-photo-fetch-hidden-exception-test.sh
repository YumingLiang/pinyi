#!/usr/bin/env bash
# check-photo-fetch.sh 规则 2 唯一例外（PhotoFetch.missingPhotoMetadata，只读元数据）的正反例。
# 每个用例在临时目录里搭一个最小的 App/，拷一份脚本进去跑，断言退出码。CI 的 Linux job 调用；本地直接运行。
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/check-photo-fetch.sh"
pass=0; failn=0

# 用法：run_case <名字> <期望 0|1> 成对的 <文件相对路径> <内容>…（PhotoFetch.swift 不传时放一个空壳）
run_case() {
  local name=$1 expect=$2; shift 2
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts" "$tmp/App/Adapters"
  cp "$script" "$tmp/scripts/check-photo-fetch.sh"
  printf 'enum PhotoFetch {}\n' > "$tmp/App/Adapters/PhotoFetch.swift"
  while [ $# -ge 2 ]; do
    mkdir -p "$tmp/$(dirname "$1")"
    printf '%s\n' "$2" > "$tmp/$1"
    shift 2
  done
  local out rc
  out=$(bash "$tmp/scripts/check-photo-fetch.sh" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && rc=1
  if [ "$rc" -eq "$expect" ]; then pass=$((pass + 1)); else
    failn=$((failn + 1)); echo "FAIL: $name (expected $expect, got $rc)"; echo "$out" | sed 's/^/    /'
  fi
  rm -rf "$tmp"
}

PF=App/Adapters/PhotoFetch.swift
OK_LINE='        o.includeHiddenAssets = true   // photo-fetch: hidden-metadata-only 只读元数据分类隐藏/删除，不请求图像'
# 放在 missingPhotoMetadata 函数体里（规则 2b）
fn() { printf 'enum PhotoFetch {\n    static func missingPhotoMetadata(_ ids: [String]) -> [String: Bool] {\n        let o = PHFetchOptions()\n%s\n%s\n        return [:]\n    }\n}' "$1" "${2:-}"; }
OK_FILE=$(fn "$OK_LINE")

# ---- 正例 ----
run_case "PhotoFetch.swift 函数体里带标记和理由" 0 $PF "$OK_FILE"
run_case "函数体里注释提到 requestImage 不算" 0 $PF "$(fn "$OK_LINE" '        // 不调 requestImage')"
run_case "没有任何 includeHiddenAssets = true" 0 $PF 'o.includeHiddenAssets = false'
run_case "注释里提到不算" 0 $PF '// includeHiddenAssets = true 只能出现在 missingPhotoMetadata'

# ---- 反例 ----
run_case "PhotoFetch.swift 里无标记" 1 $PF 'o.includeHiddenAssets = true'
run_case "标记没写理由" 1 $PF 'o.includeHiddenAssets = true   // photo-fetch: hidden-metadata-only'
run_case "标记写在上一行" 1 $PF $'// photo-fetch: hidden-metadata-only 只读\no.includeHiddenAssets = true'
run_case "其他文件带标记也不放行" 1 App/Works/WorksAdapters.swift "$OK_LINE"
run_case "InternalTools 带标记也不放行" 1 App/InternalTools/TestAlbumWriter.swift "$OK_LINE"
run_case "AppTests 带标记也不放行" 1 AppTests/Foo.swift "$OK_LINE"
run_case "PhotoFetch.swift 里第二处" 1 $PF "$(fn "$OK_LINE" "$OK_LINE")"
run_case "标记不在 missingPhotoMetadata 里（2b）" 1 $PF "$OK_LINE"
run_case "标记在别的函数里（2b）" 1 $PF $'enum PhotoFetch {\n    static func other() {\n'"$OK_LINE"$'\n    }\n}'
run_case "函数体里请求图像 requestImage（2b）" 1 $PF "$(fn "$OK_LINE" '        PHImageManager.default().requestImage(for: a, targetSize: s, contentMode: .aspectFit, options: nil) { _, _ in }')"
run_case "函数体里取资源（2b）" 1 $PF "$(fn "$OK_LINE" '        _ = PHAssetResource.assetResources(for: a)')"
run_case "函数体里走缩略图加载器（2b）" 1 $PF "$(fn "$OK_LINE" '        _ = PhotoKitThumbnails()')"
run_case "标记在别处出现第二次" 1 $PF "$OK_FILE" App/Works/Foo.swift 'let x = 1 // photo-fetch: hidden-metadata-only 蹭放行'
run_case "空格变体也抓" 1 $PF 'o.includeHiddenAssets=true'
run_case "放行行之外再写一处" 1 $PF "$OK_FILE" App/Works/Foo.swift 'o.includeHiddenAssets = true'

echo "check-photo-fetch hidden-exception self-test: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
