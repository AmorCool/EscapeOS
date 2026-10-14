#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""布局与动效防复发检查（新增 `AppLayout.swift` 组件层之后）.

背景：本轮为「布局不好看」补了一层布局 / 动效组件（`TequilaDash/Views/AppLayout.swift`）——
`AppCardGrid` / `AppAdaptiveGrid` / `AppHScrollSection` / `AppHeroHeader` / `AppSectionHeader` /
`AppGridTile` 与动效 `AppMotion` + `.appAppear` / `.appPressable` / `.appSymbolBounce`。
组件有了，就有人可能**绕过组件重造**，把「设计语言」重新打散成各页各写一套。本脚本把四条
不变量机械守住：

  L1  **手写等宽多列网格**（禁）：视图层出现 `Array(repeating: GridItem(.flexible(` 或
      `LazyVGrid(columns: [GridItem(.flexible(` —— 那是 `AppCardGrid` / `AppAdaptiveGrid` 的职责。
      固定列数用 `AppCardGrid(items:columns:)`，列数自适应用 `AppAdaptiveGrid(items:minimum:)`。
      （遗留豁免：`WallpaperView.swift` / `BatteryHealthView.swift` 是组件层之前的手写网格，
      本轮不迁移，避免扩大改动面；它们已在 ALLOW 表内。）
  L2  **手搓按压反馈**（禁）：`isPressed` 只允许出现在两个「样式实现处」——
      `AppLayout.swift`（`AppPressableStyle`）与 `DesignSystem.swift`（`TintedButtonStyle`）。
      其余视图要按压反馈请走 `.appPressable()` / `TintedButtonStyle()`，别自己读 `isPressed`。
  L3  **深色品牌渐变越界**（禁）：`AppTheme.brandGradient` 只允许出现在它的定义处
      `DesignSystem.swift`（仅供紧凑图标块 `AppBrandTile` 使用）。铺到别处（尤其全宽 banner /
      全宽按钮）即违反硬规则 1 / 7（用户已明确反馈「方块 banner」「开始修复按钮太丑」）；
      要在别处用深色品牌色，请直接用 `AppBrandTile`。
  L4  **阶梯入场延迟无界 / 懒加载入场无窗口**（禁）：`AppLayout.swift` 的入场动效必须保持两个
      不变量 —— ① `AppMotion.stagger` 对序号**封顶**（含 `min(index,`）；② `AppAppear` 有
      `staggerWindow`（窗口外项零延迟、立即可见）。原因：网格是**懒加载**（滚入视野才创建单元格），
      入场延迟若按**绝对序号**无界累加，长列表（应用列表可达上百项）滚到后面格子会空白数秒 ——
      这是用户 2026-10-12 报「更多-拉起应用 上滑下滑反应一会」的根因。删掉任一不变量该 bug 即复发。
      （L4 是「组件契约」探针：它只检查这两个不变量是否仍在，属 tripwire，不做语义求值。）

判据只认**符号/结构**，不绑行号、不绑文案。扫描前先用状态机把注释屏蔽为空白（字符串保留），
故注释 / 文档里提 `AppCardGrid` 或 `isPressed` 不会误报。

用法：python3 swift_layout_motion_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号

# L1 / L2 / L3 的豁免文件（相对仓库根，正斜杠）。每一项都写明「为什么豁免」.
ALLOW = {
    # L1：组件实现处 + 组件层之前的手写网格（本轮不迁移）
    "TequilaDash/Views/AppLayout.swift": ("L1", "L2"),
    "TequilaDash/Views/Wallpaper/WallpaperView.swift": ("L1",),
    "TequilaDash/Views/BatteryHealthView.swift": ("L1",),
    # L2：两个按压样式实现处
    "TequilaDash/Views/DesignSystem.swift": ("L2", "L3"),
}

# L1 指纹：手写等宽多列网格
L1_FINGERPRINTS = (
    "Array(repeating: GridItem(.flexible(",
    "LazyVGrid(columns: [GridItem(.flexible(",
)

# L4：布局动效组件（AppLayout.swift）必须保持的「阶梯入场有界」不变量.
# 任一指纹缺失即视为该不变量被删 ⇒ 长列表（懒加载网格）滚动时格子会空白数秒
# （用户 2026-10-12 报「更多-拉起应用 上滑下滑反应一会」的根因）。
L4_FILE = "TequilaDash/Views/AppLayout.swift"
L4_REQUIRED = (
    ("min(index,", "AppMotion.stagger 对序号封顶（clamp index）"),
    ("staggerWindow", "AppAppear 的懒加载入场窗口（窗口外项零延迟）"),
)


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


def _allowed(rel, rule):
    return rule in ALLOW.get(rel, ())


def check(root):
    errs = []
    l4_seen = False

    for path in _iter_swift_files(os.path.join(root, "TequilaDash")):
        raw = io.open(path, encoding="utf-8").read()
        masked = _mask_comments(raw)
        rel = os.path.relpath(path, root).replace(os.sep, "/")

        # L1：手写等宽多列网格（应改用 AppCardGrid / AppAdaptiveGrid）
        if not _allowed(rel, "L1"):
            for fp in L1_FINGERPRINTS:
                for k in _find_all(masked, fp):
                    errs.append("[L1] %s:%d 手写等宽多列网格 —— 应改用组件："
                                "固定列数 `AppCardGrid(items:columns:)`，"
                                "列数自适应 `AppAdaptiveGrid(items:minimum:)`"
                                % (rel, _line_of(masked, k)))

        # L2：手搓按压反馈（应改用 .appPressable() / TintedButtonStyle()）
        if not _allowed(rel, "L2"):
            for k in _find_all(masked, "isPressed"):
                errs.append("[L2] %s:%d 直接读 `isPressed` 手搓按压反馈 —— "
                            "应改用 `.appPressable()`（自定义 label 按钮）或 `TintedButtonStyle()`"
                            % (rel, _line_of(masked, k)))

        # L3：深色品牌渐变越界（brandGradient 仅供 AppBrandTile）
        if not _allowed(rel, "L3"):
            for k in _find_all(masked, "brandGradient"):
                errs.append("[L3] %s:%d 在 `DesignSystem.swift` 之外引用 `brandGradient` —— "
                            "深色品牌渐变只允许在紧凑图标块 `AppBrandTile` 内使用"
                            "（硬规则 1 / 7：不做全宽深色 banner / 实底按钮）；"
                            "要在别处用深色品牌色请直接用 `AppBrandTile`"
                            % (rel, _line_of(masked, k)))

        # L4：布局动效组件的「阶梯入场有界」不变量（组件契约探针）
        if rel == L4_FILE:
            l4_seen = True
            for needle, desc in L4_REQUIRED:
                if needle not in masked:
                    errs.append("[L4] %s 缺少不变量「%s」—— 指纹 `%s` 未出现. "
                                "删掉它会让长列表滚动时格子空白数秒"
                                "（用户报「更多-拉起应用 上滑下滑反应一会」）"
                                % (rel, desc, needle))

    if not l4_seen:
        errs.append("[L4] 找不到布局动效组件 %s —— L4 无法校验（文件被改名 / 删除？）" % L4_FILE)

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_layout_motion_guard.py <仓库根>")
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
        print("命中：%d（L1 手写等宽网格 / L2 手搓按压反馈 / L3 brandGradient 越界 / "
              "L4 阶梯入场有界）" % len(errs))
        return 1
    print("L1 无手写等宽多列网格（改用 AppCardGrid / AppAdaptiveGrid）：OK")
    print("L2 无手搓按压反馈（改用 .appPressable() / TintedButtonStyle）：OK")
    print("L3 无 brandGradient 越界（仅供 AppBrandTile）：OK")
    print("L4 阶梯入场有界（stagger 封顶 + AppAppear 窗口）：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
