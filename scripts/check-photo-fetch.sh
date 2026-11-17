#!/usr/bin/env bash
# 隐藏照片守护（photo-picker-v0.1 §5.1、§6.2 第一层）：App 里所有取照片都必须走 App/Adapters/PhotoFetch.swift。
# - App/ 下（InternalTools 除外，App/Adapters/PhotoFetch.swift 自身除外）出现 `fetchAssets` / `fetchKeyAssets` 标识符就失败（含函数引用）；
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

# 1) 见下方与规则 4 合并的词法检查。

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

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: all photo fetches go through PhotoFetch; no hidden assets / hidden album."
