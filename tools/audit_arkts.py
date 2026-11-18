#!/usr/bin/env python3
"""
ArkTS 严格模式静态规范、模块解耦与鸿蒙 Stage 工程配置审计脚本（可复现扫描）
用法：
  python3 tools/audit_arkts.py
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def strip_line_comment(line: str) -> str:
    in_single = False
    in_double = False
    in_backtick = False
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if ch == "'" and not in_double and not in_backtick:
            in_single = not in_single
        elif ch == '"' and not in_single and not in_backtick:
            in_double = not in_double
        elif ch == "`" and not in_single and not in_double:
            in_backtick = not in_backtick
        elif ch == "/" and i + 1 < n and line[i + 1] == "/" and not (in_single or in_double or in_backtick):
            return line[:i]
        i += 1
    return line


def main() -> int:
    issues = []

    # 1. 扫描全仓所有 .ets 文件，检查 ArkTS 严格模式反模式与分层解耦铁律
    ets_files = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "entry")):
        dirnames[:] = [d for d in dirnames if d not in ("build", "oh_modules", ".preview")]
        for fn in filenames:
            if fn.endswith(".ets"):
                ets_files.append(os.path.join(dirpath, fn))

    pure_logic_prefixes = (
        os.path.join("entry", "src", "main", "ets", "core") + os.sep,
        os.path.join("entry", "src", "main", "ets", "render") + os.sep,
        os.path.join("entry", "src", "main", "ets", "storage") + os.sep,
        os.path.join("entry", "src", "main", "ets", "config") + os.sep,
        os.path.join("entry", "src", "main", "ets", "model") + os.sep,
        os.path.join("entry", "src", "main", "ets", "common") + os.sep,
    )

    in_block_comment = False
    for path in sorted(ets_files):
        rel = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        in_block_comment = False
        is_pure_layer = rel.startswith(pure_logic_prefixes)

        for idx, raw_line in enumerate(lines, 1):
            line = raw_line
            if in_block_comment:
                end_pos = line.find("*/")
                if end_pos == -1:
                    continue
                line = line[end_pos + 2 :]
                in_block_comment = False

            while "/*" in line:
                start_pos = line.find("/*")
                end_pos = line.find("*/", start_pos + 2)
                if end_pos == -1:
                    line = line[:start_pos]
                    in_block_comment = True
                    break
                line = line[:start_pos] + " " + line[end_pos + 2 :]

            code = strip_line_comment(line)
            if not code.strip():
                continue

            if re.search(r":\s*any\b|\bas\s+any\b|:\s*unknown\b|\bas\s+unknown\b", code):
                issues.append(f"[ArkTS any/unknown] {rel}:{idx}: {raw_line.strip()}")
            if re.search(r"\bRecord\s*<", code):
                issues.append(f"[ArkTS Record<K,V> check] {rel}:{idx}: {raw_line.strip()}")
            if re.search(r"\.\.\.\w+", code):
                issues.append(f"[ArkTS spread check] {rel}:{idx}: {raw_line.strip()}")
            if re.search(r"\b(const|let)\s*\{[^}]+\}\s*=", code):
                issues.append(f"[ArkTS object destructuring] {rel}:{idx}: {raw_line.strip()}")
            if is_pure_layer and "@kit.ArkUI" in code:
                issues.append(f"[UI Coupling Violation in Pure Layer] {rel}:{idx}: {raw_line.strip()}")
            if re.search(r"\b(pushUrl|replaceUrl)\s*\(", code):
                window_text = "".join(lines[idx - 1 : min(len(lines), idx + 8)])
                if ".catch" not in window_text:
                    issues.append(f"[Unhandled Promise on Router] {rel}:{idx}: {raw_line.strip()}")

    # 2. 核验 main_pages.json 与 ets/pages/*.ets 完全一致
    main_pages_path = os.path.join(ROOT, "entry", "src", "main", "resources", "base", "profile", "main_pages.json")
    with open(main_pages_path, "r", encoding="utf-8") as f:
        main_pages = json.load(f)["src"]

    pages_dir = os.path.join(ROOT, "entry", "src", "main", "ets", "pages")
    actual_pages = sorted(
        ["pages/" + fn[:-4] for fn in os.listdir(pages_dir) if fn.endswith(".ets")]
    )
    if sorted(main_pages) != actual_pages:
        issues.append(f"[main_pages mismatch] json={main_pages} vs files={actual_pages}")

    # 3. 核验 obfuscation-rules.txt Release 属性混淆白名单保护
    obf_path = os.path.join(ROOT, "entry", "obfuscation-rules.txt")
    with open(obf_path, "r", encoding="utf-8") as f:
        obf = f.read()
    if "-enable-property-obfuscation" in obf and "-keep-property-name" not in obf:
        issues.append(
            "[Obfuscation Hazard] entry/obfuscation-rules.txt enables -enable-property-obfuscation without -keep-property-name"
        )

    # 4. 核验中英文/默认资源表键值对称性
    base_str_path = os.path.join(ROOT, "entry", "src", "main", "resources", "base", "element", "string.json")
    zh_str_path = os.path.join(ROOT, "entry", "src", "main", "resources", "zh_CN", "element", "string.json")
    with open(base_str_path, "r", encoding="utf-8") as f:
        base_strings = {x["name"] for x in json.load(f)["string"]}
    with open(zh_str_path, "r", encoding="utf-8") as f:
        zh_strings = {x["name"] for x in json.load(f)["string"]}
    if base_strings != zh_strings:
        issues.append(f"[i18n string mismatch] base={base_strings} vs zh_CN={zh_strings}")

    # 5. 核验全部 MatePad 页面交互热区 >= 48vp (TABLET_MIN_TOUCH_HEIGHT_VP / TABLET_PRIMARY_BTN_HEIGHT_VP)
    for fn in sorted(os.listdir(pages_dir)):
        if not fn.endswith(".ets"):
            continue
        p_path = os.path.join(pages_dir, fn)
        rel_p = os.path.relpath(p_path, ROOT)
        with open(p_path, "r", encoding="utf-8") as f:
            p_lines = f.readlines()
        for idx, raw_ln in enumerate(p_lines):
            if "Button(" in raw_ln:
                win_blk = "".join(p_lines[idx : min(len(p_lines), idx + 10)])
                if ".height(" not in win_blk:
                    issues.append(f"[Tablet Touch Height Missing on Button] {rel_p}:{idx + 1}")
            m_min_h = re.search(r"minHeight:\s*(\d+)", raw_ln)
            if m_min_h and int(m_min_h.group(1)) < 48:
                issues.append(f"[Tablet minHeight < 48vp] {rel_p}:{idx + 1}: {raw_ln.strip()}")

    print(f"=== ArkTS Static & Config Audit (Root: {ROOT}) ===")
    print(f"Scanned {len(ets_files)} .ets files (including core/, render/, storage/, config/, pages/, ohosTest/).")
    print(f"Found {len(issues)} code/config issues.")
    for it in issues:
        print(" -", it)

    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
