#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 PowerShell 5.1 自己的解析器 (AST) 校验 .ps1 语法。

比 PowerShell 7 或第三方 linter 更可靠: 本项目目标环境就是 PS 5.1,
而 PS 5.1 与 PS 7 的语法支持并不完全一致。

同时检查 .ps1 是否带 UTF-8 BOM —— 这是本项目的一个真实陷阱:
PowerShell 5.1 读取无 BOM 的脚本时按系统 ANSI 代码页解码,
中文系统 (GBK) 下中文字符串会被解坏并导致语法错误。

用法:
    python scripts/check_ps_syntax.py            # 校验当前目录下所有 .ps1
    python scripts/check_ps_syntax.py a.ps1 b.ps1

退出码: 0 全部通过, 1 有问题
"""

import glob
import os
import subprocess
import sys

BAD_MARKERS = (
    "Unexpected token",
    "Missing closing",
    "Missing expression",
    "not recognized",
    "ParserError",
    "is not recognized as the name",
)


def find_ps1(args):
    if args:
        return list(args)
    found = []
    for pat in ("*.ps1", "**/*.ps1"):
        found.extend(glob.glob(pat, recursive=True))
    # 去重并保持稳定顺序
    return sorted(set(os.path.normpath(p) for p in found))


def check_bom(path):
    """返回 (是否有 BOM, 是否含非 ASCII 字符)"""
    with open(path, "rb") as f:
        raw = f.read()
    has_bom = raw[:3] == b"\xef\xbb\xbf"
    body = raw[3:] if has_bom else raw
    non_ascii = any(b > 0x7F for b in body)
    return has_bom, non_ascii


def check_syntax(path):
    """调用 PowerShell 解析器, 返回错误信息列表"""
    escaped = path.replace("'", "''")
    cmd = (
        "$ErrorActionPreference='Stop';"
        f"$errs=$null; $toks=$null;"
        f"$null=[System.Management.Automation.Language.Parser]::ParseFile('{escaped}',[ref]$toks,[ref]$errs);"
        "if($errs -and $errs.Count -gt 0){"
        "  $errs | ForEach-Object {"
        "    $m=$_.Message -replace '\\r?\\n',' ';"
        "    Write-Output ('L' + $_.Extent.StartLineNumber + ': ' + $m)"
        "  }"
        "} else { Write-Output '__OK__' }"
    )
    try:
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd],
            capture_output=True, text=True, timeout=120,
        )
    except FileNotFoundError:
        return ["PowerShell 未安装, 无法校验"]
    except subprocess.TimeoutExpired:
        return ["解析超时"]

    out = (proc.stdout or "") + (proc.stderr or "")
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    if any(l == "__OK__" for l in lines):
        return []
    if not lines:
        return ["解析无输出 (可能 PowerShell 调用失败)"]
    return [l for l in lines if any(m in l for m in BAD_MARKERS)] or lines


def main():
    files = find_ps1(sys.argv[1:])
    if not files:
        print("未找到任何 .ps1 文件")
        return 0

    print(f"检查 {len(files)} 个 PowerShell 脚本\n")
    failed = 0
    for path in files:
        errors = check_syntax(path)
        has_bom, non_ascii = check_bom(path)

        problems = list(errors)
        # .ps1 含非 ASCII 时必须带 BOM, 否则 PS 5.1 按 ANSI 解码
        if non_ascii and not has_bom:
            problems.append(
                "缺少 UTF-8 BOM: 含非 ASCII 字符的 .ps1 必须带 BOM, "
                "否则 PowerShell 5.1 会用系统 ANSI 代码页解码导致语法错误"
            )

        if problems:
            failed += 1
            print(f"[FAIL] {path}")
            for p in problems:
                print(f"       {p}")
        else:
            note = "BOM=有" if has_bom else "BOM=无(纯 ASCII)"
            print(f"[ OK ] {path}   ({note})")

    print()
    if failed:
        print(f"{failed}/{len(files)} 个文件未通过")
        return 1
    print(f"全部通过 ({len(files)} 个文件)")
    return 0


if __name__ == "__main__":
    sys.exit(main())