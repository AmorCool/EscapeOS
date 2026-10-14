#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""主题「两套蓝」防复发检查（统一 accent 之后）.

背景：复核实测发现同一 App 出现**两套蓝** —— 全局 `AppTheme.accent`（原 `systemBlue`，
语义自适应）与新页面另用的写死 `AppTheme.trAccent`（`#005493`）。`I4MobileInstallView`
同页 heroChip 用 `accent`、sectionHeader 用 `trAccent`，观感不统一。

修复：合并为**单一自适应 token** `AppTheme.accent` —— 亮 `#005493`（TRApp 实测 Accent）、
暗 `#76D6FF`（提亮保证对比度），并删除 `trAccent`。本脚本把三条不变量机械守住：

  G1  `trAccent` 不得在任何 `TequilaDash/**/*.swift` 的**代码**里复现（注释里的历史说明
      不计）—— 一旦有人再引入第二套蓝即报。
  G2  `TequilaDash/Views/DesignSystem.swift` 的 `accent` 必须是**自适应色**（定义体内出现
      `userInterfaceStyle` + `.dark` 分支）—— 退回写死单值（`systemBlue` 或裸 sRGB）即报。
  G3  同文件的 `switchOnTint` 不得是独立写死的 sRGB 蓝字面量（须引用 `accent` 或走
      `userInterfaceStyle` 自适应）—— 防止经由开关色再次分叉出第二套蓝。
  G4  同文件的空态色 `emptyStateCircleFill` / `emptyStateGlyph` 必须是**自适应色**（定义体
      内出现 `userInterfaceStyle` + `.dark`）—— 退回写死浅色字面量（如 `#E0EBFE`）会在深色
      模式出现刺眼亮块即报。
  G5  `.borderedProminent` 不得与 `.tint(AppTheme.accent)` 同现（同一按钮修饰链内）—— 那是
      **实底纯蓝按钮**，深色模式下 accent（亮 `#76D6FF`）会变成亮蓝实底（对比突兀）；应改
      `TintedButtonStyle()`（透明淡蓝）。
  G6  不得用 `Color.blue.opacity(...)` 做淡底 —— systemBlue 与品牌蓝 `AppTheme.accent`
      不一致（第二套蓝残留）；应改 `AppTheme.accent.opacity(...)`。
  G7  `BrandProminentButtonStyle` 不得在任何 `TequilaDash/**/*.swift` 的**代码**里复现 ——
      那是**全宽深色渐变实底按钮**（`brandGradient` 铺满一整行），用户已明确反馈「那个开始修复
      按钮颜色太丑了」。主行动按钮应改 `TintedButtonStyle(tint: AppTheme.accent,
      radius: AppRadius.button)`（半透明着色 + 发丝描边）。
  G8  多色板系统新增的色 token（模块色 `categoryXxx` / 表面层 `surfaceXxx` / 强调变体
      `accentSoft` / `accentBorder`）在 `DesignSystem.swift` 里必须都是**自适应色**（定义体内
      出现 `userInterfaceStyle` + `.dark` 分支）—— 用户要求「更不要单一的颜色」而新增色彩层次，
      但硬规则 6 要求新增色一律明暗两套；有人退回写死单值（浅色字面量）即在深色模式出现
      刺眼亮块 / 对比不足，此条机械守住。

判据只认**符号/结构**，不绑行号、不绑文案。扫描前先用状态机把注释屏蔽为空白（字符串保留），
故注释里提 `trAccent` / `.borderedProminent` 不会误报。

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
    views = os.path.join(root, "TequilaDash", "Views")
    design = os.path.join(views, "DesignSystem.swift")

    # ── G1 / G5 / G6：全仓符号扫描（一次遍历）──
    for path in _iter_swift_files(os.path.join(root, "TequilaDash")):
        raw = io.open(path, encoding="utf-8").read()
        masked = _mask_comments(raw)
        rel = os.path.relpath(path, root).replace(os.sep, "/")

        # G1：trAccent 不得在代码里复现
        for k in _find_all(masked, "trAccent"):
            errs.append("[G1] %s:%d 出现 `trAccent` —— 第二套蓝回归"
                        "（已统一到 `AppTheme.accent`：亮 #005493 / 暗 #76D6FF）"
                        % (rel, _line_of(masked, k)))

        # G5：`.borderedProminent` 不得与 `.tint(AppTheme.accent)` 同现（实底纯蓝）
        for k in _find_all(masked, ".borderedProminent"):
            if ".tint(AppTheme.accent)" in masked[k:k + 200]:
                errs.append("[G5] %s:%d `.borderedProminent` 与 `.tint(AppTheme.accent)` 同现"
                            " —— 实底纯蓝按钮，深色下 accent 变亮蓝实底（对比突兀）；"
                            "应改 `TintedButtonStyle()`" % (rel, _line_of(masked, k)))

        # G6：不得用 `Color.blue.opacity(...)` 做淡底（第二套蓝残留）
        for k in _find_all(masked, "Color.blue.opacity("):
            errs.append("[G6] %s:%d 用 `Color.blue.opacity(...)` 做淡底 —— systemBlue 与品牌蓝"
                        "（`AppTheme.accent`）不一致（第二套蓝残留）；"
                        "应改 `AppTheme.accent.opacity(...)`" % (rel, _line_of(masked, k)))

        # G7：`BrandProminentButtonStyle` 不得复现（全宽深色渐变实底按钮，用户已反馈太丑）
        for k in _find_all(masked, "BrandProminentButtonStyle"):
            errs.append("[G7] %s:%d 出现 `BrandProminentButtonStyle` —— 全宽深色渐变实底按钮回归"
                        "（`brandGradient` 铺满一整行，用户反馈「开始修复按钮太丑」）；"
                        "主行动应改 `TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button)`"
                        % (rel, _line_of(masked, k)))

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

    # G4：空态色必须自适应（防止退回写死浅色字面量，深色模式出现刺眼亮块）
    for token in ("static let emptyStateCircleFill", "static let emptyStateGlyph"):
        pos = masked.find(token)
        name = token.replace("static let ", "")
        if pos < 0:
            errs.append("[G4] DesignSystem.swift 里找不到 `%s` —— 空态色被删？" % name)
            continue
        if "userInterfaceStyle" not in masked[pos:pos + 400] or ".dark" not in masked[pos:pos + 400]:
            errs.append("[G4] `%s` 不是自适应色（定义里缺 `userInterfaceStyle` / `.dark` 分支）"
                        " —— 退回写死浅色字面量会在深色模式出现刺眼亮块（如 `#E0EBFE`）" % name)

    # G8：多色板系统新增色 token 必须自适应（防复发：新增色彩层次退回写死单值）
    MULTI_PALETTE_TOKENS = (
        # ① 模块色（一个功能模块一个颜色）
        "static let categoryClean",
        "static let categoryDevice",
        "static let categoryStore",
        "static let categoryTreasure",
        "static let categorySettings",
        "static let categoryDownload",
        "static let categorySign",
        "static let categoryAdvanced",
        # ② 表面层（四级背景）
        "static let surfaceBase",
        "static let surfaceCard",
        "static let surfaceElevated",
        "static let surfaceSunken",
        # ③ 强调变体
        "static let accentSoft",
        "static let accentBorder",
    )
    for token in MULTI_PALETTE_TOKENS:
        pos = masked.find(token)
        name = token.replace("static let ", "")
        if pos < 0:
            errs.append("[G8] DesignSystem.swift 里找不到 `%s` —— 多色板 token 被删？" % name)
            continue
        # 以「下一个 `static let`」为界取定义窗口：固定 400 字符窗口会跨到下个 token 的
        # 自适应分支，从而把「写死单值」误判为自适应（漏报）.
        nxt = masked.find("static let", pos + len(token))
        window = masked[pos:nxt if nxt >= 0 else len(masked)]
        if "userInterfaceStyle" not in window or ".dark" not in window:
            errs.append("[G8] `%s` 不是自适应色（定义里缺 `userInterfaceStyle` / `.dark` 分支）"
                        " —— 多色板新增色必须明暗两套（硬规则 6）；"
                        "退回写死单值会在深色模式出现刺眼亮块 / 对比不足" % name)

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_theme_blue_guard.py <仓库根>")
        return 2
    root = sys.argv[1]
    if not os.path.isdir(os.path.join(root, "TequilaDash")):
        print("仓库根下找不到 TequilaDash/ ：%s" % os.path.abspath(root))
        return 2
    errs = check(root)
    print("-" * 72)
    if errs:
        for e in errs:
            print("ERROR %s" % e)
        print("命中：%d（G1 trAccent 复现 / G2 accent 非自适应 / G3 switchOnTint 写死蓝 / "
              "G4 空态色非自适应 / G5 borderedProminent+accent 实底 / G6 Color.blue.opacity 淡底 / "
              "G7 BrandProminentButtonStyle 全宽深色实底 / G8 多色板新增色非自适应）"
              % len(errs))
        return 1
    print("G1 无 trAccent 复现：OK")
    print("G2 accent 自适应（亮 #005493 / 暗 #76D6FF）：OK")
    print("G3 switchOnTint 未写死蓝：OK")
    print("G4 空态色自适应（emptyStateCircleFill / emptyStateGlyph）：OK")
    print("G5 无 `.borderedProminent` + `.tint(AppTheme.accent)` 实底按钮：OK")
    print("G6 无 `Color.blue.opacity(...)` 淡底：OK")
    print("G7 无 `BrandProminentButtonStyle` 全宽深色实底按钮：OK")
    print("G8 多色板新增色自适应（8 模块色 / 4 表面层 / accentSoft / accentBorder）：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
