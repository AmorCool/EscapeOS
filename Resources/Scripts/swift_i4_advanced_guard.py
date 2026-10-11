#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「开启高级功能」入口防复发检查（v0.3.xxx，第二版）.

背景（用户原话，两轮）：
    第一轮：「爱思为什么不能开启高级功能 如图 你到底有没有认真搞」
        ⇒ 旧入口是 `advancedShown = true` 直接弹一句**写死的免责声明**
          （「本机未安装该 App 时，此入口无法生效」），从不检测、也从不开启任何东西.
    第二轮：「爱思「开启高级功能」你没做好而且这个是单独一个功能」
        ⇒ ① 要**真正实现**（不是弹「尚未实现」的窗）；② 要有**独立入口**.

本版守住的不变量（第一版只守「不许退回写死声明」，本版加守「必须真实现 + 独立入口」）：

  G1  `EscapeOS/Views/I4MobileInstallView.swift` 不得再出现那句写死的免责声明
      （判据：代码里不出现「本机未安装该 App 时」）.
  G2  同文件必须**引用独立页** `I4AdvancedView(` —— 那个按钮必须连到真实现，
      不得再自己弹窗回话（删掉接线即报）.
  G3  `EscapeOS/Engine/I4PairingService.swift` 必须存在，且真的走 house_arrest 写沙盒
      （判据：同时出现 `openAppDocuments` 与 `8es1421dg.be`）.
  G4  `EscapeOS/Views/I4AdvancedView.swift` 必须存在，且连到引擎
      （判据：出现 `I4PairingService`）.
  G5  `EscapeOS/Views/TreasureBoxView.swift` 必须含独立入口回调
      （判据：出现 `onOpenI4Advanced`）.
  G6  `EscapeOS/Views/HomeView.swift` 必须把独立页接进导航栈
      （判据：出现 `I4AdvancedView(`）.
  G7  `EscapeOS/Engine/I4MobileInstallService.swift` 必须定义载体常量
      `static let agentBundleId = "com.ownbook.notes"`.

判据只认结构 / 符号，不绑死行号与展示文案，改文案不会误报。

用法：python3 swift_i4_advanced_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import io
import os
import sys


def _read(path):
    if not os.path.isfile(path):
        return None
    return io.open(path, encoding="utf-8").read()


def _strip_comments(src):
    r"""去掉注释、**保留字符串**的源码文本（G1 只在代码里找旧文案，注释里提到它不算违规）.

    逐字符状态机：行注释 / 块注释（支持嵌套）/ 单行串 / 三引号串。注释内容替换为空格
    （换行保留）；字符串原样保留（旧文案若被重新写进字符串，仍会被 G1 抓到）。
    转义 `\x` 跳过一对；`\\(` 插值不特殊处理（插值里出现 `//` 的场合本文件不存在）。
    """
    n = len(src)
    out = [' '] * n
    i = 0
    mode = "code"          # code / line / block / string / multiline
    block_depth = 0
    while i < n:
        ch = src[i]
        if mode == "line":
            if ch == "\n":
                out[i] = "\n"
                mode = "code"
            i += 1
            continue
        if mode == "block":
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    mode = "code"
                continue
            if ch == "\n":
                out[i] = "\n"
            i += 1
            continue
        if mode == "string":
            out[i] = ch
            if ch == chr(92):
                if i + 1 < n:
                    out[i + 1] = src[i + 1]
                i += 2
                continue
            if ch == '"':
                mode = "code"
            i += 1
            continue
        if mode == "multiline":
            out[i] = ch
            if ch == chr(92):
                if i + 1 < n:
                    out[i + 1] = src[i + 1]
                i += 2
                continue
            if src[i:i + 3] == '"' * 3:
                out[i + 1] = '"'
                out[i + 2] = '"'
                mode = "code"
                i += 3
                continue
            i += 1
            continue
        # mode == code
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            mode = "line"
            i += 2
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            mode = "block"
            block_depth = 1
            i += 2
            continue
        if src[i:i + 3] == '"' * 3:
            out[i] = '"'
            out[i + 1] = '"'
            out[i + 2] = '"'
            mode = "multiline"
            i += 3
            continue
        if ch == '"':
            out[i] = ch
            mode = "string"
            i += 1
            continue
        out[i] = ch
        i += 1
    return "".join(out)


def check(root):
    errs = []
    view = os.path.join(root, "EscapeOS", "Views", "I4MobileInstallView.swift")
    engine = os.path.join(root, "EscapeOS", "Engine", "I4MobileInstallService.swift")
    pairing = os.path.join(root, "EscapeOS", "Engine", "I4PairingService.swift")
    adv_view = os.path.join(root, "EscapeOS", "Views", "I4AdvancedView.swift")
    treasure = os.path.join(root, "EscapeOS", "Views", "TreasureBoxView.swift")
    home = os.path.join(root, "EscapeOS", "Views", "HomeView.swift")

    # ---- I4MobileInstallView.swift ----
    src = _read(view)
    if src is None:
        errs.append("[G1] 找不到 %s" % view)
    else:
        code = _strip_comments(src)   # 只在代码里判 G1；注释里提到旧文案不算违规
        if "本机未安装该 App 时" in code:
            errs.append("[G1] I4MobileInstallView.swift 又出现写死的免责声明"
                        "「本机未安装该 App 时……」—— 这是「不看设备就回话」的旧 bug，已删除，勿回退")
        if "I4AdvancedView(" not in code:
            errs.append("[G2] I4MobileInstallView.swift 未引用独立页 I4AdvancedView( ——"
                        "「开启高级功能」按钮必须连到真实现，不得再自己弹窗回话")

    # ---- I4PairingService.swift（真实现：house_arrest 写沙盒）----
    psrc = _read(pairing)
    if psrc is None:
        errs.append("[G3] 找不到 %s（真实现引擎缺失）" % pairing)
    else:
        pcode = _strip_comments(psrc)
        if "openAppDocuments" not in pcode or "8es1421dg.be" not in pcode:
            errs.append("[G3] I4PairingService.swift 未真的经 house_arrest 写沙盒"
                        "（缺 openAppDocuments 或 8es1421dg.be）—— 会退回「只说不做」")

    # ---- I4AdvancedView.swift（独立页连到引擎）----
    vsrc = _read(adv_view)
    if vsrc is None:
        errs.append("[G4] 找不到 %s（独立入口页缺失）" % adv_view)
    elif "I4PairingService" not in _strip_comments(vsrc):
        errs.append("[G4] I4AdvancedView.swift 未连到引擎 I4PairingService —— 独立页会是空壳")

    # ---- TreasureBoxView.swift（独立入口回调）----
    tsrc = _read(treasure)
    if tsrc is None:
        errs.append("[G5] 找不到 %s" % treasure)
    elif "onOpenI4Advanced" not in tsrc:
        errs.append("[G5] TreasureBoxView.swift 缺独立入口回调 onOpenI4Advanced ——"
                    "「开启高级功能」又会被藏回安装流程里")

    # ---- HomeView.swift（入口接进导航栈）----
    hsrc = _read(home)
    if hsrc is None:
        errs.append("[G6] 找不到 %s" % home)
    elif "I4AdvancedView(" not in hsrc:
        errs.append("[G6] HomeView.swift 未把独立页接进导航栈（缺 I4AdvancedView()）—— 入口点不动")

    # ---- I4MobileInstallService.swift（载体常量）----
    esrc = _read(engine)
    if esrc is None:
        errs.append("[G7] 找不到 %s" % engine)
    elif 'static let agentBundleId = "com.ownbook.notes"' not in esrc:
        errs.append("[G7] I4MobileInstallService.swift 缺少载体常量"
                    ' static let agentBundleId = "com.ownbook.notes"')

    return errs


def main():
    if len(sys.argv) < 2:
        print("用法：swift_i4_advanced_guard.py <仓库根>")
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
        print("命中：%d" % len(errs))
        return 1
    print("G1 无写死免责声明：OK")
    print("G2 安装页连到独立页：OK")
    print("G3 真实现经 house_arrest 写沙盒：OK")
    print("G4 独立页连到引擎：OK")
    print("G5 百宝箱有独立入口：OK")
    print("G6 HomeView 接进导航栈：OK")
    print("G7 载体常量存在：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
