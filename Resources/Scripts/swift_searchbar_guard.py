#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""搜索框（`.searchable`）显示模式防复发检查.

背景：`.searchable(placement: .navigationBarDrawer(displayMode:))` 的 `displayMode` 只有两档：

  - `.always`   搜索框**常驻悬浮**在内容之上；
  - `.automatic` 搜索框随滚动收起 / 展开（系统默认）.

**`List` 容器**会自动为常驻搜索框给内容做安全区内缩，所以 `List` 页用 `.always` 没问题
（全仓 `.always` 页面清一色是 `List`）。但**滚动容器（`ScrollView`）不会**：`.always` 的搜索框
会变成一层常驻浮层压在滚动内容上 —— **内容第一行被盖住**，且顶部滚动时毫无收起反馈，用户感知
就是「滑动跟没反应过来一样」。

本仓已经踩过两次同一颗雷：

  - v0.3.289 `FileSharingAppsView.swift`：「always 时搜索框常驻悬浮，列表首行会被压在搜索框
    下面（用户截图实锤「显示不全」）」，改 `.automatic` 修好；
  - 2026-10-12 `LaunchAppsView.swift`：`b48aed1` 把该页从 `List` 换成
    `ScrollView + AppAdaptiveGrid`，但搜索框仍留在 `.always` ⇒ 网格第一行被盖住，用户报
    「滑动跟没反应过来一样 原来不是那样的」。

2026-10-13 用户又要求该页搜索框「回到之前那样常驻」，于是修法升级为
**「常驻 + 自己给滚动内容让位」**：`.always` 与 `.safeAreaInset(edge: .top)` 成对出现，
让位高度由 `SearchBarInsetProbe` 从系统视图树实测（不写死）。不变量因此从
「滚动容器页禁 `.always`」精确化为「滚动容器页用 `.always` 必须同时给顶部让位」。

本脚本把这条不变量机械守住：

  S1  **滚动容器页用 `.always` 搜索框必须同时给内容让位**：任何 `EscapeOS/` 下的 `.swift`，
      只要出现 `displayMode: .always`，就必须满足二者之一 ——
        (a) 是 `List` 容器页（同文件内出现 `List {` 或 `List(`，系统会自动内缩）；
        (b) 同文件内出现 `.safeAreaInset(edge: .top`（自己把搜索框高度让出来）。
      两条都不满足 ⇒ 视为「搜索框浮在滚动内容上、第一行被盖住」⇒ 报错。
  S2  **本页 tripwire**：`EscapeOS/Views/LaunchAppsView.swift` 必须**同时**保留
      `displayMode: .always`（常驻）与 `.safeAreaInset(edge: .top`（让位）。少任一条即报错 ——
      少 `.always` 就退回「搜索框会收起」，少让位就让网格第一行被压住。

判据只认**符号/结构**，不绑行号、不绑文案。扫描前先用状态机把注释屏蔽为空白（字符串保留），
故注释 / 文档里写 `displayMode: .always` 不会误报。

用法：python3 swift_searchbar_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys

ALWAYS_FP = "displayMode: .always"
LIST_FPS = ("List {", "List(")
TOP_INSET_FP = ".safeAreaInset(edge: .top"
LAUNCH_FILE = "EscapeOS/Views/LaunchAppsView.swift"


def mask_comments(src):
    """把注释（行注释 / 块注释，支持嵌套 / 多行字符串）替换为等长空白，保留换行与字符串.

    与 `swift_layout_motion_guard.py` 同口径（注释屏蔽后再匹配，避免文档误报）。
    返回与 `src` 等长的文本，行号可原样对齐。
    """
    out = []
    i, n = 0, len(src)
    mode = "code"          # code | line | block | string | multiline
    depth = 0
    while i < n:
        c = src[i]
        if mode == "line":
            if c == "\n":
                mode = "code"
                out.append(c)
            else:
                out.append(" ")
            i += 1
        elif mode == "block":
            if src[i:i + 2] == "*/":
                depth -= 1
                out.append("  ")
                i += 2
                if depth == 0:
                    mode = "code"
            elif src[i:i + 2] == "/*":
                depth += 1
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif mode == "string":
            if c == "\\":
                out.append(src[i:i + 2])
                i += 2
            elif c == '"':
                out.append(c)
                i += 1
                mode = "code"
            else:
                out.append(c)
                i += 1
        elif mode == "multiline":
            if src[i:i + 3] == '"""':
                out.append('"""')
                i += 3
                mode = "code"
            else:
                out.append(c)
                i += 1
        else:  # code
            if src[i:i + 2] == "//":
                mode = "line"
                out.append("  ")
                i += 2
            elif src[i:i + 2] == "/*":
                mode = "block"
                depth = 1
                out.append("  ")
                i += 2
            elif src[i:i + 3] == '"""':
                mode = "multiline"
                out.append('"""')
                i += 3
            elif c == '"':
                mode = "string"
                out.append(c)
                i += 1
            else:
                out.append(c)
                i += 1
    return "".join(out)


def _iter_swift_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def check(root):
    errs = []
    launch_seen = False

    for path in _iter_swift_files(os.path.join(root, "EscapeOS")):
        raw = io.open(path, encoding="utf-8").read()
        masked = mask_comments(raw)
        rel = os.path.relpath(path, root).replace(os.sep, "/")

        # S1：滚动容器页用 `.always` 必须同时给内容让位（`List` 容器 或 顶部 safeAreaInset 占位）
        has_list = any(fp in masked for fp in LIST_FPS)
        has_top_inset = TOP_INSET_FP in masked
        if ALWAYS_FP in masked and not has_list and not has_top_inset:
            k = masked.find(ALWAYS_FP)
            errs.append("[S1] %s:%d 用了 `.always` 搜索框，但既不是 `List` 容器页、也没有给"
                        "滚动内容让位 —— 滚动容器（`ScrollView`）下 `.always` 的搜索框会"
                        "**常驻悬浮压在内容上**，内容第一行被盖住。请二选一：① 改回 "
                        "`displayMode: .automatic`（搜索框随滚动收起）；② 保留 `.always` 但"
                        "补 `.safeAreaInset(edge: .top)`（或 `.contentMargins(.top, _, for: "
                        ".scrollContent)`）把搜索框高度让出来"
                        % (rel, _line_of(masked, k)))

        # S2：本页修复落点的回归 tripwire —— 常驻（.always）与让位（顶部 safeAreaInset）必须成对
        if rel == LAUNCH_FILE:
            launch_seen = True
            if ALWAYS_FP not in masked:
                errs.append("[S2] %s 缺少 `%s` —— 用户要求搜索框常驻；改掉它搜索框就会收起"
                            % (rel, ALWAYS_FP))
            if not has_top_inset:
                errs.append("[S2] %s 缺少 `%s` —— 本页是 `ScrollView` 容器，常驻搜索框必须"
                            "配一个顶部让位，否则网格第一行会被搜索框盖住"
                            % (rel, TOP_INSET_FP))

    if not launch_seen:
        errs.append("[S2] 找不到 %s —— S2 无法校验（文件被改名 / 删除？）" % LAUNCH_FILE)

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_searchbar_guard.py <仓库根>")
        return 2
    root = sys.argv[1]
    if not os.path.isdir(os.path.join(root, "EscapeOS")):
        print("仓库根下找不到 EscapeOS/ ：%s" % os.path.abspath(root))
        return 2
    errs = check(root)
    print("-" * 72)
    if errs:
        for e in errs:
            print("ERROR %s" % e)
        print("命中：%d（S1 滚动容器用 .always 必须让位 / S2 拉起应用页常驻与让位成对）" % len(errs))
        return 1
    print("S1 滚动容器页的 `.always` 均已让位（List 容器 或 顶部 safeAreaInset）：OK")
    print("S2 拉起应用页 `.always`（常驻）+ `.safeAreaInset(edge: .top)`（让位）成对：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
