# -*- coding: utf-8 -*-
"""Cellular 隧道支持（移植 SideStore cellular refresh）防复发检查.

背景（用户原话）：
    「你看看sidestore更新的cellular refresh 也就是蜂窝网络刷新 研究一下移植过来
     因为我们现有隧道连接都依赖wifi网络 蜂窝网络无法使用的 我们要适配蜂窝网络
     并在更多-设置里新增"Cellular隧道支持"按钮 开启后对隧道连接支持蜂窝网络下连接」

机制（研究报告《研究_SideStore蜂窝刷新.md》）：
  · iOS 没有公开 API 能在 App 内编程开关蜂窝数据 ⇒ 只能用 iOS 快捷指令
    （`shortcuts://run-shortcut?name=TurnOffData` / `TurnOnData`）临时切换网络状态；
  · 判据是 `NWPathMonitor` 的 `usesInterfaceType(.wifi)`（等价 SideStore 的 `isWifiSatisfied`）；
  · 建隧道前关蜂窝 + 有界轮询隧道就绪（复用 `LocalDevVPN.isTunnelReachable()`），建完开回；
  · SideStore 维护者明确 iOS >= 26.4 cellular「do not work」⇒ 必须保留 26.4 分界、不假装能用；
  · **默认关**（`UserDefaults` 无值即 false）⇒ 开关不开时全部 no-op，不改变 Wi-Fi 下既有行为。

本脚本是「以后不会再有人破坏这套约束」的守门人，在提交前拦住。

检查范围：
  · EscapeOS/Engine/CellularTunnelManager.swift        （新增引擎文件）
  · EscapeOS/Views/RootView.swift                       （设置页开关）
  · EscapeOS/Engine/AppDiscovery.swift                  （接线点 1）
  · EscapeOS/Engine/UninstallService.swift              （接线点 2）
  · EscapeOS/Tunnel/TunnelContext.m                     （错误文案）
  · 全 EscapeOS/ 目录                                    （Wi-Fi 硬信念文案回归）

检查规则：
  R1 [ERROR] CellularTunnelManager.swift 缺失，或未定义 enabledKey = "EscapeOS.CellularTunnelSupport".
  R2 [ERROR] 设置页开关的 @AppStorage 默认值不是 false（必须默认关 ⇒ 零行为变化）.
  R3 [ERROR] 设置页找不到绑定该 @AppStorage 的 Toggle（开关没接上）.
  R4 [ERROR] AppDiscovery.swift / UninstallService.swift 未成对调用 prepareForTunnel + restoreAfterTunnel.
  R5 [ERROR] 全仓重新出现 "stay on Wi-Fi" / "保持 Wi-Fi" 的 Wi-Fi 硬信念文案.
  R6 [ERROR] CellularTunnelManager.swift 丢失 #available(iOS 26.4, *) 分界（不假装 26.4+ 能用）.

误报处理：Swift 文件匹配前先剥离注释与字符串字面量（注释里大量提到这些符号），
剥离保留换行 ⇒ 行号不错位. TunnelContext.m 的 R5 直接原文匹配（就是要抓文案本身）.

用法：
    python swift_cellular_tunnel_guard.py [仓库根，默认 .]
    仓库根 = 含 EscapeOS/ 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有 ERROR；2 = 参数/路径错误。
"""
import os
import re
import sys

MANAGER_REL = os.path.join("EscapeOS", "Engine", "CellularTunnelManager.swift")
ROOTVIEW_REL = os.path.join("EscapeOS", "Views", "RootView.swift")
DISCOVERY_REL = os.path.join("EscapeOS", "Engine", "AppDiscovery.swift")
UNINSTALL_REL = os.path.join("EscapeOS", "Engine", "UninstallService.swift")

ENABLED_KEY = "EscapeOS.CellularTunnelSupport"
WIFI_STRICT_PATTERNS = ("stay on Wi-Fi", "保持 Wi-Fi", "保持Wi-Fi")


def strip_comments_and_strings(src):
    """把注释与字符串字面量替换成等长空格（保留换行），行号不错位."""
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
            continue
        if src[i:i + 3] == '"""':
            out[i] = out[i + 1] = out[i + 2] = " "
            i += 3
            while i < n and src[i:i + 3] != '"""':
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
            continue
        if ch == '"':
            out[i] = " "
            i += 1
            while i < n:
                if src[i] == "\\":
                    out[i] = " "
                    if i + 1 < n:
                        out[i + 1] = " "
                    i += 2
                    continue
                if src[i] == '"':
                    out[i] = " "
                    i += 1
                    break
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def read(path):
    return open(path, encoding="utf-8", errors="replace").read()


def check_manager(path):
    findings = []
    if not os.path.isfile(path):
        findings.append(("R1", "找不到 %s（移植的引擎文件缺失）." % MANAGER_REL.replace("\\", "/")))
        return findings
    src = read(path)
    stripped = strip_comments_and_strings(src)
    # R1 的键名本身是**字符串字面量**，只能对原文（src）匹配 —— 剥离后它会被置空格.
    if not re.search(r'enabledKey\s*=\s*"%s"' % re.escape(ENABLED_KEY), src):
        findings.append(("R1", "%s 未定义 enabledKey = \"%s\"." % (
            MANAGER_REL.replace("\\", "/"), ENABLED_KEY)))
    if "#available(iOS 26.4" not in stripped:
        findings.append(("R6", "%s 丢失 #available(iOS 26.4, *) 分界 —— SideStore 维护者明确 "
                               "iOS >= 26.4 cellular「do not work」，必须保留该分界、不假装能用." %
                         MANAGER_REL.replace("\\", "/")))
    return findings


def check_settings_toggle(path):
    """R2/R3：设置页 @AppStorage 默认 false + Toggle 绑定该变量."""
    findings = []
    if not os.path.isfile(path):
        findings.append(("R2", "找不到 %s." % ROOTVIEW_REL.replace("\\", "/")))
        return findings
    stripped = strip_comments_and_strings(read(path))

    # 匹配 @AppStorage(CellularTunnelManager.enabledKey) private var <name> = <默认值>
    m = re.search(
        r'@AppStorage\s*\(\s*CellularTunnelManager\.enabledKey\s*\)'
        r'\s*(?:private\s+|public\s+|internal\s+)?var\s+(\w+)\s*=\s*(\w+)',
        stripped)
    if not m:
        findings.append(("R2", "%s 找不到绑定 CellularTunnelManager.enabledKey 的 @AppStorage 声明." %
                         ROOTVIEW_REL.replace("\\", "/")))
        return findings
    var_name, default_value = m.group(1), m.group(2)
    if default_value != "false":
        findings.append(("R2", "%s 的 @AppStorage(%s) 默认值为 %s —— 必须默认 false（默认关 ⇒ "
                               "开关不开时全部 no-op，不改变 Wi-Fi 下既有行为）." % (
                                   ROOTVIEW_REL.replace("\\", "/"), var_name, default_value)))
    if not re.search(r'Toggle\s*\([^)]*isOn\s*:\s*\$' + re.escape(var_name) + r'\b', stripped):
        findings.append(("R3", "%s 找不到绑定 $%s 的 Toggle（开关没接上设置页）." % (
            ROOTVIEW_REL.replace("\\", "/"), var_name)))
    return findings


def check_wiring(path, label):
    """R4：某接线点必须成对调用 prepareForTunnel + restoreAfterTunnel."""
    findings = []
    if not os.path.isfile(path):
        findings.append(("R4", "找不到接线点文件 %s（%s）." % (path.replace("\\", "/"), label)))
        return findings
    stripped = strip_comments_and_strings(read(path))
    has_prepare = re.search(r'CellularTunnelManager\.shared\.prepareForTunnel\s*\(\s*\)', stripped)
    has_restore = re.search(r'CellularTunnelManager\.shared\.restoreAfterTunnel\s*\(\s*\)', stripped)
    if not has_prepare:
        findings.append(("R4", "%s（%s）未调用 CellularTunnelManager.shared.prepareForTunnel() —— "
                               "蜂窝下建隧道前必须关蜂窝." % (path.replace("\\", "/"), label)))
    if not has_restore:
        findings.append(("R4", "%s（%s）未调用 CellularTunnelManager.shared.restoreAfterTunnel() —— "
                               "关过蜂窝后必须恢复（含失败路径，用 defer）." % (
                                   path.replace("\\", "/"), label)))
    return findings


def check_wifi_strict_text(root):
    """R5：全 EscapeOS/ 不得再出现 Wi-Fi 硬信念文案."""
    findings = []
    base = os.path.join(root, "EscapeOS")
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            if not name.endswith((".swift", ".m", ".h", ".mm")):
                continue
            full = os.path.join(dirpath, name)
            try:
                lines = read(full).splitlines()
            except OSError:
                continue
            rel = os.path.relpath(full, root).replace("\\", "/")
            for idx, line in enumerate(lines, 1):
                for pat in WIFI_STRICT_PATTERNS:
                    if pat in line:
                        findings.append(("R5", "%s:%d 出现「%s」—— Wi-Fi 硬信念文案（研究报告 §2.2/§2.3 "
                                               "证实隧道只连本地地址，与 Wi-Fi/蜂窝无关）." % (rel, idx, pat)))
                        break
    return findings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."

    if not os.path.isdir(os.path.join(root, "EscapeOS")):
        print("仓库根下找不到 EscapeOS/ ：%s" % os.path.abspath(root))
        print("用法: python swift_cellular_tunnel_guard.py [仓库根]")
        return 2

    findings = []
    findings += check_manager(os.path.join(root, MANAGER_REL))
    findings += check_settings_toggle(os.path.join(root, ROOTVIEW_REL))
    findings += check_wiring(os.path.join(root, DISCOVERY_REL), "应用列表")
    findings += check_wiring(os.path.join(root, UNINSTALL_REL), "卸载")
    findings += check_wifi_strict_text(root)

    for rule, msg in findings:
        print("ERROR %s  %s" % (rule, msg))

    print("-" * 72)
    print("检查：Cellular隧道支持（引擎文件 / 设置开关 / 两个接线点 / Wi-Fi 硬信念文案 / 26.4 分界）")
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ 引擎文件与键名齐备、开关默认关且已接上、两个接线点成对调用、"
              "无 Wi-Fi 硬信念文案、保留 iOS 26.4 分界 —— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
