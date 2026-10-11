#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""主题「两套蓝」防复发检查（统一 accent 之后）.

背景：复核实测发现同一 App 出现**两套蓝** —— 全局 `AppTheme.accent`（原 `systemBlue`，
语义自适应）与新页面另用的写死 `AppTheme.trAccent`（`#005493`）。`I4MobileInstallView`
同页 heroChip 用 `accent`、sectionHeader 用 `trAccent`，观感不统一。

修复：合并为**单一自适应 token** `AppTheme.accent` —— 亮 `#005493`（TRApp 实测 Accent）、
暗 `#76D6FF`（提亮保证对比度），并删除 `trAccent`。本脚本把三条不变量机械守住：

  G1  `trAccent` 不得在任何 `EscapeOS/**/*.swift` 的**代码**里复现（注释里的历史说明
      不计）—— 一旦有人再引入第二套蓝即报。
  G2  `EscapeOS/Views/DesignSystem.swift` 的 `accent` 必须是**自适应色**（定义体内出现
      `userInterfaceStyle` + `.dark` 分支）—— 退回写死单值（`systemBlue` 或裸 sRGB）即报。
  G3  同文件的 `switchOnTint` 不得是独立写死的 sRGB 蓝字面量（须引用 `accent` 或走
      `userInterfaceStyle` 自适应）—— 防止经由开关色再次分叉出第二套蓝。

判据只认**符号/结构**，不绑行号、不绑文案。扫描前先用状态机把注释屏蔽为空白（字符串保留），
故注释里提 `trAccent` 不会误报。

用法：python3 swift_theme_blue_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号


def _mask_comments(src):
    """把注释（行注释 / 块注释，支持嵌套）替换为等长空白，保留换行与字符串.

    逐字符状态机：code / string / 多行串 / 行注释 / 块注释；字符串里的 `\\(` 插值切回
    code（插值内的注释照样屏蔽）。返回与 `src` **等长**的文本，行号可原样对齐。
    """
    out = []
    n = len(src)
    i = 0
    mode_stack = ["code"]
    interp_depth = []          # 每层插值的括号深度
    block_depth = 0
    while i < n:
        ch = src[i]
        mode = mode_stack[-1]

        if mode in ("lineComment", "blockComment"):
            if mode == "lineComment":
                if ch == "\n":
                    out.append(ch)
                    mode_stack.pop()
                else:
                    out.append(" ")
                i += 1
                continue
            # blockComment
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                out.append(" ")
                out.append(" ")
                i += 2
                if block_depth == 0:
                    mode_stack.pop()
                continue
            out.append(ch if ch == "\n" else " ")
            i += 1
            continue

        if mode == "code":
            if ch == "/" and i + 1 < n and src[i + 1] == "/":
                mode_stack.append("lineComment")
                out.append(" ")
                i += 1
                continue
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth = 1
                mode_stack.append("blockComment")
                out.append(" ")
                i += 1
                continue
            if ch == Q:
                if src[i:i + 3] == Q * 3:
                    mode_stack.append("multiline")
                    out.append(src[i:i + 3])
                    i += 3
                    continue
                mode_stack.append("string")
                out.append(ch)
                i += 1
                continue
            if ch == "(" and interp_depth:
                interp_depth[-1] += 1
                out.append(ch)
                i += 1
                continue
            if ch == ")" and interp_depth:
                interp_depth[-1] -= 1
                if interp_depth[-1] == 0:
                    interp_depth.pop()
                    mode_stack.pop()
                out.append(ch)
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if mode == "string":
            if ch == BS:
                if i + 1 < n and src[i + 1] == "(":
                    interp_depth.append(1)
                    mode_stack.append("code")
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i:i + 2])
                i += 2
                continue
            if ch == Q:
                mode_stack.pop()
            out.append(ch)
            i += 1
            continue

        if mode == "multiline":
            if ch == BS:
                out.append(src[i:i + 2])
                i += 2
                continue
            if src[i:i + 3] == Q * 3:
                mode_stack.pop()
                out.append(src[i:i + 3])
                i += 3
                continue
            out.append(ch)
            i += 1
            continue

    return "".join(out)


def _iter_swift_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def _find_all(hay, needle):
    pos = 0
    while True:
        k = hay.find(needle, pos)
        if k < 0:
            return
        yield k
        pos = k + len(needle)


def check(root):
    errs = []
    views = os.path.join(root, "EscapeOS", "Views")
    design = os.path.join(views, "DesignSystem.swift")

    # ── G1：trAccent 不得在代码里复现 ──
    for path in _iter_swift_files(os.path.join(root, "EscapeOS")):
        raw = io.open(path, encoding="utf-8").read()
        masked = _mask_comments(raw)
        for k in _find_all(masked, "trAccent"):
            rel = os.path.relpath(path, root)
            errs.append("[G1] %s:%d 出现 `trAccent` —— 第二套蓝回归"
                        "（已统一到 `AppTheme.accent`：亮 #005493 / 暗 #76D6FF）"
                        % (rel.replace(os.sep, "/"), _line_of(masked, k)))

    # ── G2 / G3：DesignSystem.swift 里 accent 必须自适应、switchOnTint 不得写死蓝 ──
    if not os.path.isfile(design):
        errs.append("[G2] 找不到 %s" % design)
        return errs
    raw = io.open(design, encoding="utf-8").read()
    masked = _mask_comments(raw)

    # G2：`static let accent` 的定义窗口里必须出现 userInterfaceStyle + .dark
    acc = masked.find("static let accent")
    if acc < 0:
        errs.append("[G2] DesignSystem.swift 里找不到 `static let accent` —— 主强调色被删？")
    else:
        window = masked[acc:acc + 400]
        if "userInterfaceStyle" not in window or ".dark" not in window:
            errs.append("[G2] `accent` 不是自适应色（定义里缺 `userInterfaceStyle` / `.dark` 分支）"
                        " —— 退回写死单值会让深色模式对比度不足"
                        "（统一后应为 亮 #005493 / 暗 #76D6FF）")

    # G3：`switchOnTint` 定义行不得是独立写死的 sRGB 蓝字面量
    sw = masked.find("static let switchOnTint")
    if sw < 0:
        errs.append("[G3] DesignSystem.swift 里找不到 `static let switchOnTint`")
    else:
        eol = masked.find("\n", sw)
        line = masked[sw:eol if eol >= 0 else len(masked)]
        if "accent" not in line and "userInterfaceStyle" not in line:
            errs.append("[G3] `switchOnTint` 是独立写死值（未引用 `accent`、也未走自适应）"
                        " —— 会从开关色分叉出第二套蓝；应为 `= accent` 或自适应写法")

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_theme_blue_guard.py <仓库根>")
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
        print("命中：%d（G1 trAccent 复现 / G2 accent 非自适应 / G3 switchOnTint 写死蓝）" % len(errs))
        return 1
    print("G1 无 trAccent 复现：OK")
    print("G2 accent 自适应（亮 #005493 / 暗 #76D6FF）：OK")
    print("G3 switchOnTint 未写死蓝：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
