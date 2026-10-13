# -*- coding: utf-8 -*-
"""Cellular 隧道支持防复发检查.

背景（用户原话）：
    「你看看sidestore更新的cellular refresh 也就是蜂窝网络刷新 研究一下移植过来
     因为我们现有隧道连接都依赖wifi网络 蜂窝网络无法使用的 我们要适配蜂窝网络
     并在更多-设置里新增"Cellular隧道支持"按钮 开启后对隧道连接支持蜂窝网络下连接」

★ 关键更正（用户批评成立）：
    SideStore 的 cellular refresh 用 iOS 快捷指令临时关蜂窝
    （`shortcuts://run-shortcut?name=TurnOffData` / `TurnOnData`），
    **要求用户先在「快捷指令」App 里自建两个快捷指令** —— 这是把 App 该做的事推给用户.
    本仓**彻底删除**这条硬依赖，改为「不碰蜂窝开关、直接尝试连隧道；连不上就如实报错」.

机制（现方案）：
  · 判是否蜂窝：`NWPathMonitor` 的 `usesInterfaceType(.wifi)`（等价 SideStore 的 `isWifiSatisfied`）；
  · 建隧道前有界轮询隧道就绪（复用 `LocalDevVPN.isTunnelReachable()`），**不碰蜂窝开关**；
  · **默认关**（`UserDefaults` 无值即 false）⇒ 开关不开时全部 no-op，不改变 Wi-Fi 下既有行为.

本脚本是「以后不会再有人把快捷指令硬依赖加回来」的守门人，在提交前拦住.

检查范围：
  · EscapeOS/Engine/CellularTunnelManager.swift        （引擎文件）
  · EscapeOS/Views/RootView.swift                       （设置页开关）
  · EscapeOS/Engine/AppDiscovery.swift                  （接线点：应用列表，走 TunnelContext）
  · EscapeOS/Engine/UninstallService.swift              （接线点：卸载，走 TunnelContext）
  · EscapeOS/Engine/LocationEngine.swift                （接线点：虚拟定位，本次报障核心）
  · 全 EscapeOS/ 目录                                    （快捷指令硬依赖 / 误导文案 / Wi-Fi 硬信念文案）
  · 全部含 `let deviceIP = LocalDevVPN.targetIP` 的隧道入口（23 个引擎/服务/视图文件）

检查规则：
  R1 [ERROR] CellularTunnelManager.swift 缺失，或未定义 enabledKey = "EscapeOS.CellularTunnelSupport".
  R2 [ERROR] 设置页开关的 @AppStorage 默认值不是 false（必须默认关 ⇒ 零行为变化）.
  R3 [ERROR] 设置页找不到绑定该 @AppStorage 的 Toggle（开关没接上）.
  R4 [ERROR] 全仓实际代码重新出现「快捷指令硬依赖」
             （shortcuts:// / run-shortcut / TurnOffData / TurnOnData）.
  R5 [ERROR] 全仓用户可见文案重新出现「快捷指令」（即「让用户自建快捷指令」的误导文案）.
  R6 [ERROR] 任一「真正建隧道」的入口文件（含 `let deviceIP = LocalDevVPN.targetIP` 锚点）
             未调用 CellularTunnelManager.shared.prepareForTunnel()（接线断了）.
  R7 [ERROR] 全仓重新出现「把 Wi-Fi 说成前提条件」的误导文案
             （如「（Wi-Fi 下）」「建议在 Wi-Fi 下」「请连 Wi-Fi」）.

误报处理：Swift/ObjC 匹配前先剥离**注释**、保留字符串字面量 ——
R4/R5 要抓的 `shortcuts://…` 与「快捷指令」正是出现在字符串/文案里；
而注释里提到这些词（如解释「为什么不用快捷指令」）属正常说明，不该误报.
剥离保留换行 ⇒ 行号不错位.

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
LOCATION_REL = os.path.join("EscapeOS", "Engine", "LocationEngine.swift")

ENABLED_KEY = "EscapeOS.CellularTunnelSupport"

# R4：快捷指令硬依赖的实际代码痕迹.
SHORTCUT_DEP_PATTERNS = ("shortcuts://", "run-shortcut", "TurnOffData", "TurnOnData")
# R5：让用户自建快捷指令的误导文案.
SHORTCUT_TEXT_MARKER = "快捷指令"
# R7：Wi-Fi 硬信念文案（即「告诉用户必须/建议连 Wi-Fi 才能用」）.
#   补充（本轮修复）：199aae2 删掉了「保持 Wi-Fi」等，却漏了 LocationEngine.swift 的
#   「（Wi-Fi 下）」与 VirtualLocationSettingsView 的「建议在 Wi-Fi 下」——
#   因为旧模式集不含它们。这里补齐：凡把 Wi-Fi 说成前提条件的措辞一律拦下.
#   注意：不能笼统禁止「Wi-Fi」二字（如「不影响 Wi-Fi 下的连接」是如实说明，应放行），
#   故只列「Wi-Fi 作前提」的具体措辞.
WIFI_STRICT_PATTERNS = (
    "stay on Wi-Fi", "保持 Wi-Fi", "保持Wi-Fi",
    "建议在 Wi-Fi", "请连 Wi-Fi", "请连接 Wi-Fi", "需要 Wi-Fi", "需 Wi-Fi",
    "（Wi-Fi 下）", "(Wi-Fi 下)", "Wi-Fi 下才能", "只能在 Wi-Fi",
)

# R6：隧道设备地址解析的锚点行 —— 凡出现此行的文件都是「真正建隧道」的入口，
#   必须在建隧道前调用 CellularTunnelManager.shared.prepareForTunnel().
TUNNEL_DEVICEIP_ANCHOR = "let deviceIP = LocalDevVPN.targetIP"
PREPARE_CALL = "CellularTunnelManager.shared.prepareForTunnel()"

SOURCE_EXTS = (".swift", ".m", ".h", ".mm")


def strip_comments(src):
    """把注释替换成等长空格（保留换行与字符串字面量），行号不错位.

    与「剥离注释+字符串」不同：这里**保留字符串字面量** ——
    R4/R5 要抓的 `shortcuts://…` 与「快捷指令」正是出现在字符串/文案里；
    而注释里提到这些词（如解释「为什么不用快捷指令」）属正常说明，不该误报.
    """
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
        # Swift 多行字符串 """..."""：整体保留（内部不算注释）.
        if src[i:i + 3] == '"""':
            i += 3
            while i < n and src[i:i + 3] != '"""':
                i += 1
            if i < n:
                i += 3
            continue
        if src[i] == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if src[i] == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
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
        i += 1
    return "".join(out)


def read(path):
    return open(path, encoding="utf-8", errors="replace").read()


def iter_source_files(root):
    """遍历 EscapeOS/ 下所有 Swift/ObjC 源文件，产出 (相对路径, 绝对路径)."""
    base = os.path.join(root, "EscapeOS")
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            if not name.endswith(SOURCE_EXTS):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            yield rel, full


def check_manager(path):
    """R1：引擎文件存在 + 定义了 enabledKey."""
    findings = []
    if not os.path.isfile(path):
        findings.append(("R1", "找不到 %s（引擎文件缺失）." % MANAGER_REL.replace("\\", "/")))
        return findings
    # enabledKey 的值是字符串字面量，strip_comments 保留字符串 ⇒ 直接用原文匹配.
    if not re.search(r'enabledKey\s*=\s*"%s"' % re.escape(ENABLED_KEY), read(path)):
        findings.append(("R1", "%s 未定义 enabledKey = \"%s\"." % (
            MANAGER_REL.replace("\\", "/"), ENABLED_KEY)))
    return findings


def check_settings_toggle(path):
    """R2/R3：设置页 @AppStorage 默认 false + Toggle 绑定该变量."""
    findings = []
    if not os.path.isfile(path):
        findings.append(("R2", "找不到 %s." % ROOTVIEW_REL.replace("\\", "/")))
        return findings
    stripped = strip_comments(read(path))

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


def check_no_shortcut_dependency(root):
    """R4：全仓实际代码不得再出现「快捷指令硬依赖」（注释里的说明不算）."""
    findings = []
    for rel, full in iter_source_files(root):
        try:
            lines = strip_comments(read(full)).splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, 1):
            for pat in SHORTCUT_DEP_PATTERNS:
                if pat in line:
                    findings.append(("R4", "%s:%d 出现「%s」—— 快捷指令硬依赖（用户须自建快捷指令）"
                                           "已被彻底删除，禁止加回. 蜂窝下直接尝试连隧道、连不上如实报错即可." % (
                                               rel, idx, pat)))
                    break
    return findings


def check_no_shortcut_text(root):
    """R5：全仓用户可见文案不得再出现「快捷指令」（让用户自建快捷指令的误导文案）."""
    findings = []
    for rel, full in iter_source_files(root):
        try:
            lines = strip_comments(read(full)).splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, 1):
            if SHORTCUT_TEXT_MARKER in line:
                findings.append(("R5", "%s:%d 出现「%s」—— 「让用户自建快捷指令」的误导文案；"
                                       "本仓已不依赖快捷指令，禁止出现." % (rel, idx, SHORTCUT_TEXT_MARKER)))
    return findings


def check_wiring(path, label):
    """R6：某接线点必须调用 prepareForTunnel()."""
    findings = []
    if not os.path.isfile(path):
        findings.append(("R6", "找不到接线点文件 %s（%s）." % (path.replace("\\", "/"), label)))
        return findings
    stripped = strip_comments(read(path))
    if not re.search(r'CellularTunnelManager\.shared\.prepareForTunnel\s*\(\s*\)', stripped):
        findings.append(("R6", "%s（%s）未调用 CellularTunnelManager.shared.prepareForTunnel() —— "
                               "蜂窝下建隧道前必须有界等隧道就绪." % (path.replace("\\", "/"), label)))
    return findings


def check_wiring_all_tunnel_entries(root):
    """R6（泛化）：所有「真正建隧道」的入口文件都必须调用 prepareForTunnel().

    判据：文件含锚点 `let deviceIP = LocalDevVPN.targetIP`（即该处解析设备地址去建隧道）.
    只看**实际代码**（strip_comments 后），避免被注释里的说明误报.
    """
    findings = []
    for rel, full in iter_source_files(root):
        if not rel.endswith(".swift"):
            continue
        try:
            stripped = strip_comments(read(full))
        except OSError:
            continue
        if TUNNEL_DEVICEIP_ANCHOR not in stripped:
            continue
        if PREPARE_CALL not in stripped:
            findings.append(("R6", "%s 含隧道入口锚点「%s」，却未调用 %s —— "
                                   "蜂窝下建隧道前必须先有界等隧道就绪." % (
                                       rel, TUNNEL_DEVICEIP_ANCHOR, PREPARE_CALL)))
    return findings


def check_wifi_strict_text(root):
    """R7：全 EscapeOS/ 不得再出现 Wi-Fi 硬信念文案."""
    findings = []
    for rel, full in iter_source_files(root):
        try:
            lines = strip_comments(read(full)).splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, 1):
            for pat in WIFI_STRICT_PATTERNS:
                if pat in line:
                    findings.append(("R7", "%s:%d 出现「%s」—— Wi-Fi 硬信念文案（研究报告 §2.2/§2.3 "
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
    findings += check_no_shortcut_dependency(root)
    findings += check_no_shortcut_text(root)
    findings += check_wiring(os.path.join(root, DISCOVERY_REL), "应用列表")
    findings += check_wiring(os.path.join(root, UNINSTALL_REL), "卸载")
    findings += check_wiring(os.path.join(root, LOCATION_REL), "虚拟定位")
    findings += check_wiring_all_tunnel_entries(root)
    findings += check_wifi_strict_text(root)

    for rule, msg in findings:
        print("ERROR %s  %s" % (rule, msg))

    print("-" * 72)
    print("检查：Cellular隧道支持（引擎文件 / 设置开关 / 无快捷指令硬依赖 / 无误导文案 / "
          "全部隧道入口接线 / 无 Wi-Fi 硬信念文案）")
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ 引擎文件与键名齐备、开关默认关且已接上、无快捷指令硬依赖与误导文案、"
              "全部隧道入口均已调用 prepareForTunnel、无 Wi-Fi 硬信念文案 —— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
