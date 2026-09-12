#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 PowerShell 5.1 自己的解析器 (AST) 校验 .ps1 语法。

为什么不用 PS 7 或第三方 linter: 本项目目标环境是 PS 5.1, 而两者的语法支持
并不完全一致。用目标版本自己的解析器最可靠。

同时检查 .ps1 是否带 UTF-8 BOM —— 这是本项目的一个真实陷阱:
PowerShell 5.1 读取无 BOM 的脚本时按系统 ANSI 代码页解码, 中文系统 (GBK) 下
中文字符串会被解坏并导致语法错误。

用法:
    python scripts/check_ps_syntax.py            # 校验当前目录下所有 .ps1
    python scripts/check_ps_syntax.py a.ps1 b.ps1

退出码: 0 全部通过, 1 有问题
"""

import glob
import os
import subprocess
import sys

# 子进程交互统一按 UTF-8, 避免 Windows 上默认 ANSI 代码页导致解码异常
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 只认这些关键字, 避免把解析器的其它提示误判为语法错误
BAD_MARKERS = (
    "Unexpected token",
    "Missing closing",
    "Missing expression",
    "Missing argument",
    "Terminator expected",
    "not recognized",
    "ParserError",
)

# 注意: 这里不能设 $ErrorActionPreference='Stop'。
# 解析出错时它会抛终止异常, 反而让 errs 收集逻辑执行不到, 把真正的
# 语法错误吞掉 —— 这正是上一版 CI 失败却看不出原因的原因之一。
PS_CMD = (
    "$ErrorActionPreference='Continue';"
    "$errs=$null; $toks=$null;"
    "try {"
    "  $null=[System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$toks,[ref]$errs);"
    "} catch { Write-Output ('L0: PARSE_THREW ' + $_.Exception.Message); exit 0 };"
    "if ($errs -and $errs.Count -gt 0) {"
    "  foreach ($e in $errs) {"
    "    $m = ($e.Message -replace '\\r?\\n',' ');"
    "    Write-Output ('L' + $e.Extent.StartLineNumber + ': ' + $m);"
    "  }"
    "} else { Write-Output '__OK__' }"
)


def find_ps1(args):
    if args:
        return list(args)
    found = []
    for pat in ("*.ps1", "**/*.ps1"):
        found.extend(glob.glob(pat, recursive=True))
    return sorted(set(os.path.normpath(p) for p in found))


def check_bom(path):
    """返回 (是否有 BOM, 是否含非 ASCII 字节, 读取错误)"""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        return False, False, str(e)
    has_bom = raw[:3] == b"\xef\xbb\xbf"
    body = raw[3:] if has_bom else raw
    non_ascii = any(b > 0x7F for b in body)
    return has_bom, non_ascii, None


def run_powershell(exe, cmd):
    """执行 PowerShell 命令, 返回 (输出文本, 错误说明)"""
    try:
        proc = subprocess.run(
            [exe, "-NoProfile", "-NonInteractive", "-Command", cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
    except FileNotFoundError:
        return None, f"{exe} 不存在"
    except subprocess.TimeoutExpired:
        return None, "解析超时"
    except OSError as e:
        return None, f"调用失败: {e}"

    text = proc.stdout or ""
    if text.startswith("\ufeff"):
        text = text.lstrip("\ufeff")
    # 个别环境会给出 UTF-16 输出, 做一次容错
    if "\x00" in text:
        try:
            text = text.encode("latin-1", "ignore").decode("utf-16-le", "replace")
        except Exception:
            pass
    return text, None


def check_syntax(path):
    """校验单个文件, 返回错误描述列表"""
    escaped = path.replace("'", "''")
    cmd = PS_CMD % escaped

    for exe in ("powershell", "pwsh"):
        text, err = run_powershell(exe, cmd)
        if err:
            if exe == "pwsh":
                return [f"无法调用 PowerShell: {err}"]
            continue

        lines = [l.strip() for l in text.splitlines() if l.strip()]
        if "__OK__" in lines:
            return []
        hits = [l for l in lines if any(m in l for m in BAD_MARKERS)]
        if hits:
            return hits
        # 没有明确错误关键字, 也没拿到 __OK__: 原样带出输出便于排查
        if lines:
            return ["解析输出异常: " + " | ".join(lines[:5])]
        return ["解析无输出 (PowerShell 调用可能失败)"]
    return ["未找到可用的 PowerShell (powershell / pwsh 都不可用)"]


def main():
    files = find_ps1(sys.argv[1:])
    if not files:
        print("未找到任何 .ps1 文件")
        return 0

    print(f"检查 {len(files)} 个 PowerShell 脚本\n")
    failed = 0
    for path in files:
        errors = check_syntax(path)
        has_bom, non_ascii, read_err = check_bom(path)

        problems = list(errors)
        if read_err:
            problems.append(f"读取失败: {read_err}")
        # 含非 ASCII 的 .ps1 必须带 BOM
        if non_ascii and not has_bom:
            problems.append(
                "缺少 UTF-8 BOM: 含非 ASCII 字符的 .ps1 必须带 BOM, 否则 "
                "PowerShell 5.1 会按系统 ANSI 代码页解码导致语法错误"
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
