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
run_case "InternalTools 不查规则 4" 0 App/InternalTools/Tool.swift $'#if INTERNAL_TOOLS\nlet r = PhotoFetch.allImages(order: .newestFirst)\n#endif'
run_case "前缀相同的别的名字" 0 $F 'let r = PhotoFetch.imagesCount + PhotoFetch.allImagesTotal'

# ---- #19 follow-up：QA 攻击 A1–A12（qa/tests/pr19/check-photo-fetch-attack.sh），必须报红 ----
run_case "A1 typealias 别名" 1 $F $'typealias PF = PhotoFetch\nlet r = PF.allImages(order: .x)'
run_case "A2 PhotoFetch.self 存进变量" 1 $F $'let t = PhotoFetch.self\nlet r = t.allImages(order: .x)'
run_case "A3 反引号成员名" 1 $F 'let r = PhotoFetch.`allImages`(order: .x)'
run_case "A4 名字和点之间块注释" 1 $F 'let r = PhotoFetch/* x */.allImages(order: .x)'
run_case "A5 链式调用中间空一行" 1 $F $'let r = PhotoFetch\n\n    .allImages(order: .x)'
run_case "A6 链式第一行行尾注释" 1 $F $'let r = PhotoFetch // 取全部\n    .allImages(order: .x)'
run_case "A7 extension 里不带前缀调用" 1 $F $'extension PhotoFetch {\n  static func everything() -> R { allImages(order: .x) }\n}'
run_case "A8 extension 里 Self. 调用" 1 $F $'extension PhotoFetch {\n  static func e2() -> R { Self.images(withLocalIdentifiers: ids) }\n}'
run_case "A9 别的目录下同名 PhotoFetch.swift" 1 App/Works/PhotoFetch.swift 'let r = PhotoFetch.allImages(order: .x)'
run_case "A10 字符串里写标记" 1 $F 'let r = PhotoFetch.allImages(order: .x); let note = "// photo-fetch: raw-ok x"'
run_case "A11 一个标记盖两处原始调用" 1 $F 'let a = PhotoFetch.allImages(order: .x); let b = PhotoFetch.images(withLocalIdentifiers: ids)   // photo-fetch: raw-ok 懒加载'
run_case "A12 规则 1：fetchAssets 函数引用" 1 $F 'let f = PHAsset.fetchAssets; let r = f(nil)'
run_case "字符串插值里调用" 1 $F 'let s = "n = \(PhotoFetch.allImages(order: .x).count)"'
run_case "多行字符串插值里调用" 1 $F $'let s = """\n  \\(PhotoFetch.keyAssets(in: c))\n  """'
run_case "块注释里的标记不算" 1 $F 'let r = PhotoFetch.allImages(order: .x) /* photo-fetch: raw-ok x */'
run_case "typealias 泛型写法" 1 $F 'typealias PF<T> = PhotoFetch'
run_case "PhotoFetch.Type" 1 $F 'func f(_ t: PhotoFetch.Type) {}'
run_case "规则 1 fetchKeyAssets 带空格" 1 $F 'let r = PHAsset.fetchKeyAssets (in: c, options: nil)'

# ---- #19 follow-up 正例 ----
run_case "字符串里提到原始 API" 0 $F 'let msg = "PhotoFetch.allImages 不能直接用；fetchAssets 也不行"'
run_case "块注释里提到" 0 $F $'/* PhotoFetch.allImages(order:)\n   PHAsset.fetchAssets */\nlet x = 1'
run_case "插值里调 visible*" 0 $F 'let s = "n = \(PhotoFetch.visibleAllImagesCount())"'
run_case "多行链式 + 调用行行尾标记" 0 $F $'let r = PhotoFetch\n    .allImages(order: .x)   // photo-fetch: raw-ok 网格懒加载'
run_case "同一行一处原始调用 + 一处 pickerSources" 0 $F 'let r = PhotoFetch.images(in: c, sources: PhotoFetch.pickerSources(forSubtype: s))   // photo-fetch: raw-ok 懒加载'
run_case "原始字符串 #\"…\"#" 0 $F 'let s = #"PhotoFetch.allImages "quoted" \(x)"#'
run_case "名字里含 fetchAssets 的别的标识符" 0 $F 'let fetchAssetsCount = 3; let myfetchAssets = 1'

echo "check-photo-fetch tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
