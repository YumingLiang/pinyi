#!/usr/bin/env python3
r"""从文案表（App/Resources/copy_v1.1.md）生成 zh-Hans 的 Localizable.strings / InfoPlist.strings。

规则：
- 只解析形如 `| \`key\` | 用途 | 文案 |` 的表格行；key 原样作为 .strings 的 key。
- `plist.*` 写入 InfoPlist.strings，Info.plist 键取自「用途」列（如 `NSPhotoLibraryUsageDescription`），
  其余写入 Localizable.strings。
- `app.display_name` 只进 Localizable.strings（App 内显示用），**不再**写入 InfoPlist.strings 的
  CFBundleDisplayName：主屏幕显示名改由构建配置 `APP_DISPLAY_NAME` 决定（Release「拼忆」/ Internal「拼忆内测」），
  InfoPlist.strings 里的本地化值会覆盖 Info.plist，导致内测包也显示「拼忆」。copy 表的 app.display_name
  与 Release 的 APP_DISPLAY_NAME 须保持一致（`--check` 校验）。
- 占位符 `{name}` 按出现顺序转为位置参数 `%1$@`、`%2$@`…（调用方传 String），原名记在注释里。
- key 重复或格式异常时报错退出。纯本地脚本，不联网。

用法：python3 scripts/gen-localizable.py [--check]   （--check：只校验生成结果与仓库中一致）
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "App/Resources/copy_v1.1.md"
OUT_DIR = ROOT / "App/Resources/zh-Hans.lproj"
ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$")
PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def convert(text: str):
    names = []

    def repl(m):
        names.append(m.group(1))
        return f"%{len(names)}$@"

    return PLACEHOLDER.sub(repl, text.replace("%", "%%")), names


def check_display_name(names):
    """copy 表的 app.display_name 必须与 project.yml 里 Release 的 APP_DISPLAY_NAME 一致。"""
    if len(names) != 1:
        sys.exit(f"app.display_name must appear exactly once, got {len(names)}")
    yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    m = re.search(r"^\s+Release:\s*\n(?:\s+#.*\n)*\s+APP_DISPLAY_NAME:\s*(\S+)", yml, re.M)
    if not m:
        sys.exit("project.yml: Release APP_DISPLAY_NAME not found")
    if m.group(1) != names[0]:
        sys.exit(f"Release APP_DISPLAY_NAME {m.group(1)!r} != copy app.display_name {names[0]!r}")


def build():
    seen = {}
    loc, plist, display_names = [], [], []
    for lineno, line in enumerate(SRC.read_text(encoding="utf-8").splitlines(), 1):
        m = ROW.match(line)
        if not m:
            continue
        key, usage, text = m.groups()
        if key in seen:
            sys.exit(f"duplicate key {key!r} at lines {seen[key]} and {lineno}")
        seen[key] = lineno
        value, names = convert(text)
        comment = f"/* {usage}（copy_v1.1.md:{lineno}）"
        if names:
            comment += " 参数: " + ", ".join(f"%{i + 1}$@={n}" for i, n in enumerate(names))
        comment += " */"
        if key.startswith("plist."):
            plist_key = usage.strip("` ")
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", plist_key):
                sys.exit(f"cannot derive Info.plist key from usage column at line {lineno}: {usage!r}")
            plist.append(f'{comment}\n"{plist_key}" = "{escape(value)}";\n')
        else:
            loc.append(f'{comment}\n"{key}" = "{escape(value)}";\n')
            if key == "app.display_name":
                display_names.append(value)
    check_display_name(display_names)
    header = "/* 自动生成：python3 scripts/gen-localizable.py —— 请改 copy_v1.1.md 后重新生成，勿手改。 */\n\n"
    return header + "\n".join(loc), header + "\n".join(plist), len(loc), len(plist)


def main():
    loc, plist, nl, np = build()
    targets = {OUT_DIR / "Localizable.strings": loc, OUT_DIR / "InfoPlist.strings": plist}
    if "--check" in sys.argv:
        stale = [str(p) for p, c in targets.items() if not p.exists() or p.read_text(encoding="utf-8") != c]
        if stale:
            sys.exit("stale generated files: " + ", ".join(stale))
        print(f"OK: {nl} Localizable keys, {np} InfoPlist keys up to date")
        return
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for p, c in targets.items():
        p.write_text(c, encoding="utf-8")
    print(f"wrote {nl} Localizable keys, {np} InfoPlist keys")


if __name__ == "__main__":
    main()
