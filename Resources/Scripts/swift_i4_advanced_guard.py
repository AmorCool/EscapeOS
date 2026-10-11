#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「开启高级功能」入口防复发检查（v0.3.591）.

背景（用户原话）：
    「爱思为什么不能开启高级功能 如图 你到底有没有认真搞」

根因：该入口原先是 `advancedShown = true` 直接弹一句**写死的免责声明**
（「本机未安装该 App 时，此入口无法生效」）—— 从不检测设备、也从不开启任何东西，
与同页「安装状态：安装成功」自相矛盾（用户截图 IMG_6873）。修法 = 点它时**读设备实际状态**
（爱思移动端 `com.ownbook.notes` 装没装）再如实回话，并说明配对（写 `pair.config`）本仓尚未实现。

本脚本把「不许退回写死声明」这条不变量机械守住：

  G1  `EscapeOS/Views/I4MobileInstallView.swift` 不得再出现那句写死的免责声明
      （判据：文件里不出现「本机未安装该 App 时」）.
  G2  同文件 `开启高级功能` 的弹窗正文必须由状态变量驱动（判据：出现 `Text(advancedMessage)`），
      不得是写死的字面量.
  G3  同文件必须真的做设备检测（判据：同时出现 `agentBundleId` 与 `probeDevice(`）——
      删掉检测即报（否则又变回「不看设备就回话」）.
  G4  `EscapeOS/Engine/I4MobileInstallService.swift` 必须定义载体常量
      `static let agentBundleId = "com.ownbook.notes"`（高级功能设备端载体）.

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

    src = _read(view)
    if src is None:
        errs.append("[G1] 找不到 %s" % view)
    else:
        code = _strip_comments(src)   # 只在代码里判 G1；注释里提到旧文案不算违规
        if "本机未安装该 App 时" in code:
            errs.append("[G1] I4MobileInstallView.swift 又出现写死的免责声明"
                        "「本机未安装该 App 时……」—— 这是「不看设备就回话」的旧 bug，已删除，勿回退")
        if "Text(advancedMessage)" not in code:
            errs.append("[G2] 「开启高级功能」弹窗正文不再由状态变量驱动（缺 Text(advancedMessage)）"
                        " —— 又变回写死文案？")
        if "agentBundleId" not in code or "probeDevice(" not in code:
            errs.append("[G3] 「开启高级功能」入口没有做设备检测（缺 agentBundleId / probeDevice(）"
                        " —— 会退回「不读设备直接回话」")

    esrc = _read(engine)
    if esrc is None:
        errs.append("[G4] 找不到 %s" % engine)
    elif 'static let agentBundleId = "com.ownbook.notes"' not in esrc:
        errs.append("[G4] I4MobileInstallService.swift 缺少载体常量"
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
        print("命中：%d（G1 无写死声明 / G2 弹窗由状态驱动 / G3 有设备检测 / G4 载体常量）" % len(errs))
        return 1
    print("G1 无写死免责声明：OK")
    print("G2 弹窗由状态变量驱动：OK")
    print("G3 入口做设备检测：OK")
    print("G4 载体常量存在：OK")
    print("命中：0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
