#!/usr/bin/env python3
"""Swift 源码的**轻量字符串自检** —— 在推 CI 之前先跑它.

## 为什么要有这个（血泪）
用脚本批量改 Swift 时，有两次把**真换行**插进了字符串字面量里，产生
「Unterminated string literal」，而**本机没有 Swift 编译器**、只能等 CI 跑 6 分钟才发现.
更糟的是「bash -> python -> 文件」这条链会把反斜杠 n 折叠成真换行，肉眼还看不出来.

## 它查什么
逐行数**裸双引号**（跳过反斜杠转义与 `//` 注释行）—— 奇数 = 字符串没在本行闭合.
Swift 里跨行字符串要么用三引号、要么显式用 + 拼接，所以「一行里引号是奇数」
几乎总是 bug（多行拼接的续行形如 `+ "..."`，引号仍是偶数）.

## 用法
    python3 Resources/Scripts/lint_swift_strings.py <文件或目录> [...]

退出码：0 干净；1 有可疑行.

注意：这是**廉价启发式**，不替代编译器；目的是把「一眼能看出的低级错误」挡在 CI 之前.
"""

import io
import os
import sys

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号


def lint(path):
    """返回「裸双引号个数为奇数」的行号列表."""
    bad = []
    for i, line in enumerate(io.open(path, encoding="utf-8").read().split(chr(10)), 1):
        st = line.strip()
        if not st or st.startswith("//"):
            continue
        count = 0
        j = 0
        while j < len(line):
            c = line[j]
            if c == BS:
                j += 2          # 跳过转义对
                continue
            if c == Q:
                count += 1
            j += 1
        if count % 2 == 1:
            bad.append(i)
    return bad


def collect(args):
    out = []
    for a in args:
        if os.path.isdir(a):
            for root, _, names in os.walk(a):
                out += [os.path.join(root, n) for n in names if n.endswith(".swift")]
        elif a.endswith(".swift"):
            out.append(a)
    return sorted(out)


def main():
    files = collect(sys.argv[1:])
    if not files:
        print("用法：lint_swift_strings.py <文件或目录> [...]")
        return 1
    ok = True
    for p in files:
        bad = lint(p)
        if bad:
            ok = False
            print("FAIL", p, "可疑行", bad[:10])
            lines = io.open(p, encoding="utf-8").read().split(chr(10))
            for i in bad[:3]:
                print("     L%d: %s" % (i, lines[i - 1].strip()[:90]))
    print("LINT", "PASS" if ok else "FAIL", "（检查了 %d 个文件）" % len(files))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
