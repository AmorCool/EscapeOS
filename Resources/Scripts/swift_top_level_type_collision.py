# -*- coding: utf-8 -*-
"""Swift 顶层类型名冲突普查。

为什么需要它：`swiftc -parse` 是**单文件**解析，查不出「两个文件声明了同名顶层类型」；
而 Swift 不允许同一 module 内顶层类型重名（即使其中一个是 private）⇒ 这类错误**只有 CI 全量编译才发现**。
本项目已因此炸过一次 CI（`AppIconView` 被 BackupsListView 与 SignSourceAppListView 同时声明）。

用法：在仓库根目录跑
    python swift_top_level_type_collision.py [仓库根，默认 .]
退出码：0 = 无冲突；1 = 有冲突（并打印清单）

注意：**只看顶层声明**（行首无缩进）。缩进的嵌套类型（如各宿主类型里的 `enum CodingKeys`）
重名是合法的，不要误报。
"""
import os
import re
import sys
import collections

DECL = re.compile(
    r'^(?:public |internal |private |fileprivate |final |open )*'
    r'(struct|class|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)', re.M)


def scan(root):
    owners = collections.defaultdict(list)
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if not f.endswith(".swift"):
                continue
            p = os.path.join(dirpath, f)
            try:
                src = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in DECL.finditer(src):
                line = src[:m.start()].count("\n") + 1
                owners[m.group(2)].append((p.replace("\\", "/"), line, m.group(1)))
    return owners


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    owners = scan(root)
    dups = {k: v for k, v in owners.items() if len(v) > 1}
    print("顶层类型声明总数: %d" % sum(len(v) for v in owners.values()))
    print("顶层重名组数: %d" % len(dups))
    for k, v in sorted(dups.items()):
        print("  %-32s %s" % (k, "   ".join("%s:%d(%s)" % x for x in v)))
    if not dups:
        print("  （无重名）")
    return 1 if dups else 0


if __name__ == "__main__":
    sys.exit(main())
