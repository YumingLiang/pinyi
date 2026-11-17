#!/usr/bin/env bash
# check-photo-fetch.sh 规则 4 的正反例（QA #19 第 7 节 V1–V7 + 行级标记）。每个用例在临时目录里搭一个最小的 App/，
# 拷一份脚本进去跑，断言退出码。CI 的 Linux job 调用；本地直接运行。
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/check-photo-fetch.sh"
pass=0; failn=0

# 用法：run_case <名字> <期望 0|1> <文件相对路径> <内容>（可再跟成对的 路径 内容）
run_case() {
  local name=$1 expect=$2; shift 2
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts" "$tmp/App/Adapters"
  cp "$script" "$tmp/scripts/check-photo-fetch.sh"
  printf 'enum PhotoFetch { static func allImages() {} }\n' > "$tmp/App/Adapters/PhotoFetch.swift"
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

F=App/Adapters/Foo.swift
# ---- 反例：必须报红 ----
run_case "V1 allImages 直接用" 1 $F 'let r = PhotoFetch.allImages(order: .newestFirst)'
run_case "images(in:) 直接用" 1 $F 'let r = PhotoFetch.images(in: c, sources: s)'
run_case "keyAssets 直接用" 1 $F 'let r = PhotoFetch.keyAssets(in: c)'
run_case "V3 括号后空格" 1 $F 'let r = PhotoFetch.images( in: c, sources: s)'
run_case "点前后空格" 1 $F 'let r = PhotoFetch . images(in: c, sources: s)'
run_case "V4 换行链式调用" 1 $F $'let r = PhotoFetch\n    .images(in: c, sources: s)'
run_case "上一行以点结尾" 1 $F $'let r = PhotoFetch.\n    allImages(order: .newestFirst)'
run_case "V5 函数引用" 1 $F 'let f = PhotoFetch.allImages'
run_case "V6 新文件按 ID 取图" 1 $F 'let r = PhotoFetch.images(withLocalIdentifiers: ids)'
run_case "按 ID 原始结果（#15 后无存量放行）" 1 App/Works/WorksAdapters.swift 'let a = PhotoFetch.images(withLocalIdentifiers: x)'
run_case "按 ID 原始结果在缩略图加载器" 1 App/Adapters/PhotoKitThumbnails.swift 'PhotoKitLibrary.array(PhotoFetch.images(withLocalIdentifiers: ids))'
run_case "V2 不再整文件放行 PhotoKitLibrary" 1 App/Adapters/PhotoKitLibrary.swift 'let n = PhotoFetch.images(in: c, sources: s).count'
run_case "V7 不再整文件放行 PhotoKitAssetGrid" 1 App/Adapters/PhotoKitAssetGrid.swift 'return PhotoFetch.allImages(order: .newestFirst)'
run_case "标记没写理由" 1 $F 'let r = PhotoFetch.allImages(order: .newestFirst)   // photo-fetch: raw-ok'
run_case "标记写在上一行" 1 $F $'// photo-fetch: raw-ok 网格\nlet r = PhotoFetch.allImages(order: .newestFirst)'
run_case "includeHiddenAssets = true（规则 2）" 1 $F 'o.includeHiddenAssets = true'

# ---- 正例：必须通过 ----
run_case "visibleImages(in:)" 0 $F 'let r = PhotoFetch.visibleImages(in: c, sources: s)'
run_case "visibleImages(withLocalIdentifiers:)" 0 $F 'let r = PhotoFetch.visibleImages(withLocalIdentifiers: ids)'
run_case "visibleKeyAssets / visibleAllImagesCount" 0 $F $'let a = PhotoFetch.visibleKeyAssets(in: c)\nlet n = PhotoFetch.visibleAllImagesCount()'
run_case "同一行标记 + 理由" 0 $F 'let r = PhotoFetch.allImages(order: .newestFirst)   // photo-fetch: raw-ok 网格懒加载，VisibleIndexMap 跳过隐藏项'
run_case "注释里提到原始 API" 0 $F $'/// 以前用 `PhotoFetch.images(in:)`\n// PhotoFetch.allImages 已不用'
run_case "#15 isPickedAssetAvailable" 0 $F 'guard PhotoFetch.isPickedAssetAvailable(id) else { return }'
run_case "PhotoFetch.swift 自己" 0 App/Adapters/PhotoFetch.swift $'enum PhotoFetch { static func x() { _ = PhotoFetch.allImages(order: .x) } }'
run_case "InternalTools 不查规则 4" 0 App/InternalTools/Tool.swift 'let r = PhotoFetch.allImages(order: .newestFirst)'
run_case "前缀相同的别的名字" 0 $F 'let r = PhotoFetch.imagesCount + PhotoFetch.allImagesTotal'

echo "check-photo-fetch tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
