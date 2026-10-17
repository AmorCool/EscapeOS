#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""提交前统一换行符 —— 让工作区文件的 EOL 与 git 基线一致。

## 为什么需要它

本仓源文件的换行符**不统一**：
  · 大部分 .swift / .m / .rs 在 git 里存的是 LF
  · 但工作区检出时被转成了 CRLF（Windows 默认）
  · 少数文件（如 project.yml、TunnelContext.m）git 里就是 CRLF

我的编辑工具会按工作区当前的 EOL 重写整个文件。如果判断错了基线，
git diff 就会显示「整文件重写」（几千行），把真实改动（几十行）淹没。

## 它做什么

对每个改动文件：
  1. 从 `git cat-file blob <baseline>:<path>` 取基线内容
  2. 判断基线是 CRLF 还是 LF
  3. 把工作区文件统一成同一种 EOL

## 用法

    python Resources/Scripts/normalize_eol.py            # 处理所有未提交改动
    python Resources/Scripts/normalize_eol.py --check    # 只检查不修改
    python Resources/Scripts/normalize_eol.py --base a2a91a5

退出码：0 = 已统一 / 无需处理；1 = --check 模式下发现不一致。
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args),
                          capture_output=True)


def changed_files(base):
    """返回相对基线改过的文件（含未跟踪的新文件）。"""
    out = git("diff", "--name-only", base).stdout.decode("utf-8", "replace")
    files = [f for f in out.split() if f]
    untracked = git("ls-files", "--others", "--exclude-standard").stdout.decode("utf-8", "replace")
    files += [f for f in untracked.split() if f]
    return sorted(set(files))


def baseline_eol(base, rel):
    """基线文件的换行风格：返回 b"\\r\\n" 或 b"\\n"；取不到时返回 None。"""
    blob = git("cat-file", "blob", "%s:%s" % (base, rel)).stdout
    if not blob:
        return None
    return b"\r\n" if blob.count(b"\r\n") > 0 else b"\n"


def main():
    check_only = "--check" in sys.argv
    base = "HEAD"
    for i, a in enumerate(sys.argv):
        if a == "--base" and i + 1 < len(sys.argv):
            base = sys.argv[i + 1]

    files = changed_files(base)
    if not files:
        print("没有改动的文件")
        return 0

    bad = []
    for rel in files:
        path = os.path.join(REPO, rel.replace("/", os.sep))
        if not os.path.exists(path):
            continue
        want = baseline_eol(base, rel)
        if want is None:
            continue          # 新文件：没有基线，不动
        cur = open(path, "rb").read()
        norm = cur.replace(b"\r\n", b"\n")
        target = norm.replace(b"\n", b"\r\n") if want == b"\r\n" else norm
        if target != cur:
            bad.append(rel)
            if not check_only:
                open(path, "wb").write(target)

    if not bad:
        print("换行符全部与基线一致（%d 个文件）" % len(files))
        return 0

    if check_only:
        print("以下 %d 个文件换行符与基线不一致：" % len(bad))
        for f in bad:
            print("  " + f)
        return 1

    print("已统一 %d 个文件的换行符：" % len(bad))
    for f in bad:
        print("  " + f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
