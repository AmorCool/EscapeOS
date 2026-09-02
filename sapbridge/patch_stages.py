#!/usr/bin/env python3
"""
OpenList 源码阶段标记注入（崩溃定位用，v0.3.86）。

用法：python3 patch_stages.py <openlist-src-dir>

给 internal/bootstrap 与 internal/db 的每个导出函数注入：
  - 函数入口：StageMarkLocal("<Func>-begin")
  - defer 出口：StageMarkLocal("<Func>-done")
标记写到 conf.Conf.DataDir（宿主模块数据目录，SSH `mlog` 可读）。
跑一次崩溃 → 对照标记文件存在性 → 函数级定位崩溃点。

幂等：已注入（stagemark_local.go 存在）则跳过。
"""
from __future__ import annotations

import pathlib
import re
import sys

TEMPLATE = """//go:build !nomark

package __PKG__

import (
\t"os"
\t"path/filepath"
\t"time"

\t"github.com/OpenListTeam/OpenList/v4/internal/conf"
)

// StageMarkLocal writes a marker file for crash localization.
// Injected by EscapeOS build (v0.3.86); NOT part of upstream OpenList.
func StageMarkLocal(name string) {
\tdefer func() { _ = recover() }()
\tvar dir string
\tfunc() {
\t\tdefer func() { _ = recover() }()
\t\tdir = conf.Conf.DataDir
\t}()
\tif dir == "" {
\t\tdir = os.TempDir()
\t}
\t_ = os.MkdirAll(dir, 0755)
\t_ = os.WriteFile(filepath.Join(dir, "stage-"+name+".txt"),
\t\t[]byte(time.Now().Format("15:04:05.000")), 0644)
}
"""

PKG_RE = re.compile(r"^package\s+(\w+)", re.M)
FUNC_RE = re.compile(r"(?m)^func\s+([A-Z]\w*)\s*\(([^)]*)\)\s*([^{]*)\{\s*$")


def inject(dir_path: pathlib.Path) -> int:
    pkg = None
    for f in sorted(dir_path.glob("*.go")):
        m = PKG_RE.search(f.read_text(encoding="utf-8"))
        if m:
            pkg = m.group(1)
            break
    if not pkg:
        print(f"  skip (no package): {dir_path}")
        return 0
    marker = dir_path / "stagemark_local.go"
    if marker.exists():
        print(f"  already injected: {dir_path}")
        return 0
    marker.write_text(TEMPLATE.replace("__PKG__", pkg), encoding="utf-8")
    total = 0
    for f in sorted(dir_path.glob("*.go")):
        if f.name == "stagemark_local.go":
            continue
        txt = f.read_text(encoding="utf-8")
        cnt = [0]

        def repl(m: re.Match) -> str:
            cnt[0] += 1
            name = m.group(1)
            return (m.group(0) + '\n\tStageMarkLocal("' + name +
                    '-begin")\n\tdefer StageMarkLocal("' + name + '-done")')

        new = FUNC_RE.sub(repl, txt)
        if cnt[0]:
            f.write_text(new, encoding="utf-8")
            total += cnt[0]
            print(f"  marked {f.name}: {cnt[0]} func(s)")
    return total


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: patch_stages.py <openlist-src-dir>")
        return 2
    src = pathlib.Path(sys.argv[1])
    if not src.exists():
        print(f"source dir missing: {src}")
        return 1
    grand = 0
    for sub in ("internal/bootstrap", "internal/db"):
        d = src / sub
        if d.exists():
            grand += inject(d)
        else:
            print(f"  skip (missing): {d}")
    print(f"total injected: {grand}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
