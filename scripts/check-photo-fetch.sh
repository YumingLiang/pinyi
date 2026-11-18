#!/usr/bin/env bash
# 隐藏照片守护（photo-picker-v0.1 §5.1、§6.2 第一层）：App 里所有取照片都必须走 App/Adapters/PhotoFetch.swift。
# - App/ 下（InternalTools 除外，App/Adapters/PhotoFetch.swift 自身除外）出现 `fetchAssets` / `fetchKeyAssets` 标识符就失败（含函数引用，不要求带括号）；
# - 任何地方把 includeHiddenAssets 设成 true 就失败。唯一例外：App/Adapters/PhotoFetch.swift 的 `func classifyMissing` 里、同一行带 `// photo-fetch: hidden-metadata-only <理由>` 的那一处，且该函数只读元数据、不请求图像（规则 2 / 2b）。全仓只许这一处。
# - 任何地方在代码里引用 smartAlbumAllHidden 就失败（PhotoFetch.swift 里只在注释中出现）。
# 只看代码行：整行注释（// 或 ///）不算。CI 的 Linux job 调用；本地也可直接运行。
# 第二层是 AppTests/PhotoFetchTests.swift（macOS job）：断言 PhotoFetch 生成的选项 includeHiddenAssets == false。
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 每条管道末尾 `|| true`：set -o pipefail 下 grep 没匹配会返回 1。
# 去掉整行注释后再匹配：grep 输出是 path:line:content，content 以 // 开头（允许前导空白）的丢掉。
code_only() { grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' || true; }

# 1) 见下方与规则 4 合并的词法检查。

# 2) includeHiddenAssets 不允许设为 true（含 InternalTools）。
#    唯一例外（需求 4.8 第 5e 条，架构师 11-17 意见二）：PhotoFetch.swift 里只读元数据的缺图分类
#    （`PhotoFetch.classifyMissing`，只看查不查得到、isHidden，不请求图像）。放行条件全部满足才算：
#    - 在 App/Adapters/PhotoFetch.swift；
#    - 同一行带 `// photo-fetch: hidden-metadata-only <理由>`，理由不能空；
#    - 全仓只有这一处（标记出现第二次，不论在哪个文件，都失败）。
hidden_marker='//[[:space:]]*photo-fetch:[[:space:]]*hidden-metadata-only'
matches=$(grep -rEn --include='*.swift' 'includeHiddenAssets[[:space:]]*=[[:space:]]*true' App AppTests 2>/dev/null | code_only || true)
bad=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if printf '%s' "$line" | grep -q '^App/Adapters/PhotoFetch.swift:' \
     && printf '%s' "$line" | grep -Eq "${hidden_marker}[[:space:]]+[^[:space:]]"; then
    continue
  fi
  bad="${bad}${line}"$'\n'
done <<< "$matches"
if [ -n "$bad" ]; then
  echo "::error::includeHiddenAssets = true is forbidden (only exception: PhotoFetch.classifyMissing with '// photo-fetch: hidden-metadata-only <reason>' on the same line):"
  printf '%s' "$bad"
  fail=1
fi
markers=$(grep -rEn --include='*.swift' "$hidden_marker" App AppTests 2>/dev/null | code_only || true)
if [ -n "$markers" ] && [ "$(printf '%s\n' "$markers" | wc -l)" -gt 1 ]; then
  echo "::error::'photo-fetch: hidden-metadata-only' may appear exactly once (PhotoFetch.classifyMissing):"
  echo "$markers"
  fail=1
fi

# 2b) 唯一例外那一行必须在 `func classifyMissing` 的函数体里，且函数体里不得请求任何图像
#     （PHImageManager / requestImage / 资源 / 编辑输入 / 缩略图等一律不许出现）。函数体 = 从声明行到下一行只有 `    }` 的行。
pf=App/Adapters/PhotoFetch.swift
if [ -f "$pf" ] && grep -Eq "$hidden_marker" "$pf"; then
  range=$(awk '/func[[:space:]]+classifyMissing[[:space:]]*\(/ { s = NR } s && NR > s && /^    }[[:space:]]*$/ { print s, NR; exit }' "$pf")
  marker_line=$(grep -En "$hidden_marker" "$pf" | head -1 | cut -d: -f1)
  if [ -z "$range" ]; then
    echo "::error::$pf: 'photo-fetch: hidden-metadata-only' must sit inside func classifyMissing"
    fail=1
  else
    set -- $range
    if [ "$marker_line" -le "$1" ] || [ "$marker_line" -ge "$2" ]; then
      echo "::error::$pf:$marker_line: 'photo-fetch: hidden-metadata-only' must sit inside func classifyMissing (lines $1-$2)"
      fail=1
    fi
    body=$(sed -n "${1},${2}p" "$pf" | grep -Ev '^[[:space:]]*//' || true)
    if printf '%s' "$body" | grep -Eq 'PHImageManager|PHCachingImageManager|requestImage|requestAVAsset|requestLivePhoto|requestContentEditingInput|PHAssetResource|requestData|PhotoKitThumbnails|ImagePixels|CGImage|UIImage'; then
      echo "::error::$pf: classifyMissing may only read metadata (exists / isHidden); it must not request any image:"
      printf '%s\n' "$body" | grep -En 'PHImageManager|PHCachingImageManager|requestImage|requestAVAsset|requestLivePhoto|requestContentEditingInput|PHAssetResource|requestData|PhotoKitThumbnails|ImagePixels|CGImage|UIImage'
      fail=1
    fi
  fi
fi

# 3) 不允许在代码里引用「已隐藏」智能相簿（InternalTools 也不行；PhotoFetch.swift 只在注释里提到）。
matches=$(grep -rn --include='*.swift' 'smartAlbumAllHidden' App 2>/dev/null | code_only || true)
if [ -n "$matches" ]; then
  echo "::error::smartAlbumAllHidden must never be referenced in code:"
  echo "$matches"
  fail=1
fi

# 1) 和 4) 用同一个 Swift 词法预处理（python3，嵌在本脚本里，自测只需拷这一个文件）：
#    去掉注释（// 和可嵌套的 /* */）和字符串字面量（含多行 """、#"…"#；字符串插值 \( … ) 里仍按代码查），保留行号；
#    反引号成员名还原；按整文件（跨行）匹配，所以换行、空行、行尾注释、块注释都拆不开调用链。（#19 follow-up，QA 攻击 A1–A12）
#
# 1) `fetchAssets` / `fetchKeyAssets` 只允许出现在 App/Adapters/PhotoFetch.swift（按完整路径，不按文件名）和 App/InternalTools/。
#    匹配标识符本身（`\bfetchAssets\b`），函数引用（不带括号）也算。
# 4) 未过滤的取图结果要走 isHidden 后置过滤（相簿多选 PR 合并条件；QA #19 第 7 节收紧）：
#    PhotoFetch.allImages / images(in:…) / images(withLocalIdentifiers:…) / keyAssets 的原始结果，除 App/Adapters/PhotoFetch.swift（完整路径）外，
#    一律改用 visibleImages(in:) / visibleImages(withLocalIdentifiers:) / visibleObjects / visibleAllImagesCount / visibleKeyAssets。
#    - 确实要拿原始 fetch result 的（网格懒加载、素材扫描分批取），在**这次调用所在行的行尾注释**里写 `// photo-fetch: raw-ok <理由>`，
#      理由不能空；字符串里的标记不算；一个标记只放行一处调用（同一行两处原始调用直接失败）。
#    - 同时禁止能把 PhotoFetch 换个名字再调用的写法：`typealias X = PhotoFetch`、`PhotoFetch.self`；
#      `extension PhotoFetch` 只允许写在 App/Adapters/PhotoFetch.swift（extension 里不带前缀 / `Self.` 调用拦不住）。
#    - InternalTools 不查规则 4（内部工具，不进正式包，见规则 5 的前提，如有）。
#    测试：scripts/tests/check-photo-fetch-test.sh（正反例，含 QA 攻击 A1–A12）。
ROOT_APP="${PHOTO_FETCH_APP_DIR:-App}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "::error::check-photo-fetch.sh needs python3 (rules 1 / 4)"
  exit 1
fi
if ! python3 - "$ROOT_APP" <<'PY'
import os, re, sys
root = sys.argv[1].rstrip('/')
fetch_file = os.path.join(root, 'Adapters', 'PhotoFetch.swift')
internal = os.path.join(root, 'InternalTools') + os.sep

def lex(src):
    """返回 (code, comments)：code 与 src 等长，注释和字符串内容换成空格（换行保留）；comments = [(行号, 行注释文本)]。"""
    out = list(src)
    comments = []
    i, n, line = 0, len(src), 1
    # 栈：('code', paren_depth) 或 ('str', hashes, multiline)
    stack = [('code', 0)]
    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '
    while i < n:
        top = stack[-1]
        c = src[i]
        if top[0] == 'code':
            if src.startswith('//', i):
                j = src.find('\n', i)
                j = n if j < 0 else j
                comments.append((line, src[i:j]))
                blank(i, j); i = j; continue
            if src.startswith('/*', i):
                depth, j = 0, i
                while j < n:
                    if src.startswith('/*', j): depth += 1; j += 2; continue
                    if src.startswith('*/', j):
                        depth -= 1; j += 2
                        if depth == 0: break
                        continue
                    j += 1
                line += src.count('\n', i, j)
                blank(i, j); i = j; continue
            m = re.match(r'(#*)("""|")', src[i:i+64])
            if m:
                hashes = len(m.group(1)); q = m.group(2)
                stack.append(('str', hashes, q == '"""'))
                i += len(m.group(0)); continue
            if c == '(':
                stack[-1] = ('code', top[1] + 1)
            elif c == ')':
                if top[1] == 0 and len(stack) > 1:
                    stack.pop(); i += 1; continue   # 插值结束，回到字符串
                stack[-1] = ('code', max(0, top[1] - 1))
            if c == '\n': line += 1
            i += 1; continue
        # 字符串里
        _, hashes, multi = top
        esc = '\\' + '#' * hashes
        if src.startswith(esc + '(', i):
            blank(i, i + len(esc) + 1); i += len(esc) + 1
            stack.append(('code', 0)); continue
        if src.startswith(esc, i):
            blank(i, min(n, i + len(esc) + 1)); i += len(esc) + 1; continue
        close = ('"""' if multi else '"') + '#' * hashes
        if src.startswith(close, i):
            stack.pop(); i += len(close); continue
        if c == '\n':
            line += 1
            if not multi:   # 单行字符串不会跨行（防御：未闭合时回到代码）
                stack.pop()
            i += 1; continue
        if c != '\n': out[i] = ' '
        i += 1
    code = ''.join(out).replace('`', ' ')
    return code, comments

def line_of(code, pos):
    return code.count('\n', 0, pos) + 1

marker = re.compile(r'^//\s*photo-fetch:\s*raw-ok\s+\S')
raw_call = re.compile(r'\bPhotoFetch\s*\.\s*(allImages|images|keyAssets)\b')
alias_bans = [
    (re.compile(r'\btypealias\s+\w+(\s*<[^>]*>)?\s*=\s*PhotoFetch\b'), 'typealias to PhotoFetch'),
    (re.compile(r'\bPhotoFetch\s*\.\s*(self|Type)\b'), 'PhotoFetch.self / PhotoFetch.Type'),
    (re.compile(r'\bextension\s+PhotoFetch\b'), 'extension PhotoFetch outside App/Adapters/PhotoFetch.swift'),
]
rule1 = re.compile(r'\b(fetchAssets|fetchKeyAssets)\b')

errors1, errors4 = [], []
for d, _, files in os.walk(root):
    for f in sorted(files):
        if not f.endswith('.swift'): continue
        path = os.path.join(d, f)
        if os.path.normpath(path) == os.path.normpath(fetch_file): continue
        try:
            src = open(path, encoding='utf-8').read()
        except UnicodeDecodeError:
            src = open(path, encoding='latin-1').read()
        code, comments = lex(src)
        lines = src.split('\n')
        def show(ln): return '%s:%d:%s' % (path, ln, lines[ln - 1].strip() if ln - 1 < len(lines) else '')
        in_internal = (path + os.sep).startswith(internal) or path.startswith(internal)
        if not in_internal:
            for m in rule1.finditer(code):
                errors1.append(show(line_of(code, m.start())))
        if in_internal: continue
        for rx, what in alias_bans:
            for m in rx.finditer(code):
                errors4.append('%s   [%s]' % (show(line_of(code, m.start())), what))
        marked = {ln for ln, text in comments if marker.match(text)}
        per_line = {}
        for m in raw_call.finditer(code):
            ln = line_of(code, m.start(1))
            per_line.setdefault(ln, []).append(m)
        for ln, ms in sorted(per_line.items()):
            if ln in marked and len(ms) == 1: continue
            why = 'one raw-ok marker covers only one raw call' if ln in marked else 'missing // photo-fetch: raw-ok <reason>'
            errors4.append('%s   [%s]' % (show(ln), why))

rc = 0
if errors1:
    print("::error::fetchAssets / fetchKeyAssets must go through PhotoFetch (App/Adapters/PhotoFetch.swift):")
    print('\n'.join(errors1)); rc = 1
if errors4:
    print("::error::raw PhotoFetch results must go through PhotoFetch.visible* (isHidden post-filter), or carry '// photo-fetch: raw-ok <reason>' as the trailing comment of that call's line:")
    print('\n'.join(errors4)); rc = 1
sys.exit(rc)
PY
then
  fail=1
fi

# 5) InternalTools 豁免（规则 1 / 4 放行 App/InternalTools/，含 TestAlbumWriter 的 fetchAssets）只在这些文件确实只进内测包时成立
#    （架构师 11-17 第 6 条）：
#    - App/InternalTools/ 下每个 .swift 第一行代码是 `#if INTERNAL_TOOLS`、最后一行代码是 `#endif`（Release 编不进来）；
#    - InternalTools 里的类型（TestAlbumWriter / InternalTools*）不在 App/InternalTools 以外被引用（正式包不依赖它）；
#    - project.yml：INTERNAL_TOOLS 编译条件只出现在 Debug / Internal 配置，Release 没有；Config/*.xcconfig 不定义它（Release 共用）；
#      App/InternalTools 不被别的 target（如 PhotoMosaicTests）当源码收进去。
#    测试：scripts/tests/check-photo-fetch-internal-test.sh（正反例）。
if [ -d "$ROOT_APP/InternalTools" ]; then
  while IFS= read -r -d '' f; do
    first=$(awk '!/^[[:space:]]*(\/\/.*)?$/ { sub(/[[:space:]]+$/, ""); print; exit }' "$f")
    last=$(awk '!/^[[:space:]]*(\/\/.*)?$/ { l = $0 } END { sub(/[[:space:]]+$/, "", l); print l }' "$f")
    if [ "$first" != "#if INTERNAL_TOOLS" ] || [ "$last" != "#endif" ]; then
      echo "::error::$f: InternalTools files must be wrapped in '#if INTERNAL_TOOLS' ... '#endif' (first/last code line) so they only build into the Internal app"
      fail=1
    fi
  done < <(find "$ROOT_APP/InternalTools" -name '*.swift' -print0)
  types=$(grep -rhoE '^[[:space:]]*(final[[:space:]]+)?(struct|class|enum|actor|protocol)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
            --include='*.swift' "$ROOT_APP/InternalTools" | awk '{print $NF}' | sort -u || true)
  for t in $types; do
    refs=$(grep -rnw --include='*.swift' "$t" "$ROOT_APP" AppTests 2>/dev/null | grep -v "^$ROOT_APP/InternalTools/" | code_only || true)
    # 主 App 里的入口按钮只能在 #if INTERNAL_TOOLS 里（这里按引用文件逐个查：引用行必须在 #if INTERNAL_TOOLS 块内）
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      rf=${r%%:*}; rest=${r#*:}; rl=${rest%%:*}
      if ! awk -v L="$rl" 'NR < L && /^[[:space:]]*#if[[:space:]]+INTERNAL_TOOLS/ { d++ } NR < L && /^[[:space:]]*#endif/ && d > 0 { d-- } NR == L { exit (d > 0 ? 0 : 1) }' "$rf"; then
        echo "::error::$rf:$rl: InternalTools type '$t' referenced outside '#if INTERNAL_TOOLS'"
        fail=1
      fi
    done <<< "$refs"
  done
fi
if [ -f project.yml ]; then
  bad_cfg=$(awk '
    /^[A-Za-z]/ { top = $1 }
    /^    [A-Za-z]+:[[:space:]]*$/ { cfg = $1; sub(":", "", cfg) }
    /INTERNAL_TOOLS/ && $0 !~ /^[[:space:]]*#/ && cfg != "Debug" && cfg != "Internal" { print NR ": " $0 }' project.yml || true)
  if [ -n "$bad_cfg" ]; then
    echo "::error::project.yml: INTERNAL_TOOLS may only be set in the Debug / Internal configs:"
    echo "$bad_cfg"
    fail=1
  fi
  if grep -nE '^[[:space:]]*-[[:space:]]*(path:[[:space:]]*)?"?App/InternalTools' project.yml >/dev/null; then
    echo "::error::project.yml: App/InternalTools must not be added as sources of another target"
    fail=1
  fi
fi
if ls Config/*.xcconfig >/dev/null 2>&1 && grep -nE '^[^/]*INTERNAL_TOOLS' Config/*.xcconfig; then
  echo "::error::Config/*.xcconfig must not define INTERNAL_TOOLS (Release shares these files)"
  fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: all photo fetches go through PhotoFetch; no hidden assets / hidden album."
