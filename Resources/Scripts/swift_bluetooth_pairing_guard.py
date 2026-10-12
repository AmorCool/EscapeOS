# -*- coding: utf-8 -*-
"""蓝牙定位「免配对」防复发检查 —— 防复发机制.

背景（用户原话）：
    「我们更多-虚拟定位里的蓝牙模拟定位 你看爱思盒子为什么就支持蓝牙定位 不需要配对连接呢
     有点脱裤子放屁了 我们好像强制要求需要配对连接Localdev才能」

结论（见 研究_蓝牙定位免配对.md）：
  · 蓝牙链路（`BLECoordinator`）本身**不需要系统蓝牙配对**，也不需要配对文件 / VPN 隧道；
  · 旧实现却把「必须已导入配对文件」当成蓝牙下行的前置门控 ——
    `SpoofSession` 的 `guard hasPairing` + `BluetoothPanelView` 的警告段与按钮 `.disabled`，
    用户在 B 机上被卡在「先配对」这一步（真正该做的是让 `LocationEngine.set` 如实报错）；
  · v0.3.594 去掉这两层门控：蓝牙下行不再事前拦截，注入能否成功由引擎如实上报。

本脚本是「以后不会再有人把配对门控加回蓝牙路径」的守门人，在提交前拦住。

检查范围：
  · `EscapeOS/Engine/SpoofSession.swift` 的 `SpoofSession` 类型体
  · `EscapeOS/Views/VirtualLocation/BluetoothPanelView.swift` 的 `BluetoothPanelView` 类型体

检查规则：
  R1 [ERROR] `SpoofSession` 体内出现 `guard hasPairing` —— 注入路径不得再用配对文件做前置守卫.
  R2 [ERROR] `SpoofSession` 体内出现 `if !hasPairing` —— 同上（另一种阻断写法）.
  R3 [ERROR] `BluetoothPanelView` 体内出现 `hasPairing` —— 蓝牙面板不得再读配对状态做门控.

误报处理：匹配前**先剥离注释与字符串字面量**（注释里会提到 `hasPairing`），剥离保留换行，行号不错位.

用法：
    python swift_bluetooth_pairing_guard.py [仓库根，默认 .]
    仓库根 = 含 EscapeOS/ 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有 ERROR；2 = 参数/路径错误。
"""
import os
import re
import sys

SESSION_REL = os.path.join("EscapeOS", "Engine", "SpoofSession.swift")
PANEL_REL = os.path.join("EscapeOS", "Views", "VirtualLocation", "BluetoothPanelView.swift")

SESSION_TYPE = "SpoofSession"
PANEL_TYPE = "BluetoothPanelView"

# R1/R2：SpoofSession 体内不得出现的「配对前置守卫」写法.
SESSION_GUARD_PATTERNS = [
    ("R1", re.compile(r'\bguard\s+hasPairing\b'),
     "`guard hasPairing` —— 注入路径不得再用配对文件做前置守卫，应交给 LocationEngine.set 如实报错."),
    ("R2", re.compile(r'\bif\s*!\s*hasPairing\b'),
     "`if !hasPairing` —— 同上（另一种阻断写法），不得在注入前拦下蓝牙下行."),
]

# R3：BluetoothPanelView 体内不得出现的标识符.
PANEL_FORBIDDEN = ("hasPairing",)


def strip_comments_and_strings(src):
    """把注释与字符串字面量替换成等长空格（保留换行）.

    处理 `//` 行注释、`/* */` 块注释（不嵌套）、双引号单行串、三引号多行串.
    注释/串内的字符一律置空格，但**换行保留** ⇒ 行号与原文一致.
    """
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        # 行注释
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        # 块注释（不嵌套）
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            out[i] = " "
            out[i + 1] = " "
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
        # 多行字符串
        if src[i:i + 3] == '"""':
            out[i] = out[i + 1] = out[i + 2] = " "
            i += 3
            while i < n and src[i:i + 3] != '"""':
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                if i + 2 < n:
                    out[i + 2] = " "
                i += 3
            continue
        # 单行字符串
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


def find_type_body(stripped, name):
    """在已剥离注释/串的源码里，取 `struct/class/enum/func <name>` 的 `{...}` 体.

    返回 (body_text, body_start_offset) 或 None. 用花括号配对（此时花括号都是代码里的）.
    """
    m = re.search(r'\b(?:struct|class|enum|func)\s+' + re.escape(name) + r'\b', stripped)
    if not m:
        return None
    brace = stripped.find("{", m.end())
    if brace < 0:
        return None
    depth = 0
    for j in range(brace, len(stripped)):
        if stripped[j] == "{":
            depth += 1
        elif stripped[j] == "}":
            depth -= 1
            if depth == 0:
                return stripped[brace:j + 1], brace
    return None


def line_of(stripped, offset):
    """绝对偏移 → 1 基行号（stripped 保留换行，行号与原文一致）."""
    return stripped.count("\n", 0, offset) + 1


def check_session(src):
    """SpoofSession：返回 findings: [(rule, relpath, message)]."""
    findings = []
    stripped = strip_comments_and_strings(src)
    found = find_type_body(stripped, SESSION_TYPE)
    if found is None:
        findings.append(("R1", SESSION_REL, "找不到类型 %s（它应定义在 %s）." % (SESSION_TYPE, SESSION_REL)))
        return findings
    body, base = found
    for rule, pattern, message in SESSION_GUARD_PATTERNS:
        for m in pattern.finditer(body):
            findings.append((rule, SESSION_REL,
                "%s:%d %s" % (SESSION_TYPE, line_of(stripped, base + m.start()), message)))
    return findings


def check_panel(src):
    """BluetoothPanelView：返回 findings: [(rule, relpath, message)]."""
    findings = []
    stripped = strip_comments_and_strings(src)
    found = find_type_body(stripped, PANEL_TYPE)
    if found is None:
        findings.append(("R3", PANEL_REL, "找不到类型 %s（它应定义在 %s）." % (PANEL_TYPE, PANEL_REL)))
        return findings
    body, base = found
    for token in PANEL_FORBIDDEN:
        for m in re.finditer(r'\b' + re.escape(token) + r'\b', body):
            findings.append(("R3", PANEL_REL,
                "%s:%d 出现 %s —— 蓝牙面板不得再读配对状态做门控（警告段 / 按钮 .disabled 都不行）."
                % (PANEL_TYPE, line_of(stripped, base + m.start()), token)))
    return findings


def read(path):
    return open(path, encoding="utf-8", errors="replace").read()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."

    session_path = os.path.join(root, SESSION_REL)
    panel_path = os.path.join(root, PANEL_REL)

    for path in (session_path, panel_path):
        if not os.path.isfile(path):
            print("找不到 %s" % path)
            print("用法: python swift_bluetooth_pairing_guard.py [仓库根]")
            return 2

    try:
        findings = check_session(read(session_path)) + check_panel(read(panel_path))
    except OSError as e:
        print("读取失败: %s" % e)
        return 2

    for rule, rel, msg in findings:
        print("ERROR %s  [%s] %s" % (rel.replace("\\", "/"), rule, msg))

    print("-" * 72)
    print("检查：%s 与 %s" % (SESSION_REL.replace("\\", "/"), PANEL_REL.replace("\\", "/")))
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ 蓝牙路径无配对门控（SpoofSession 无 guard hasPairing、BluetoothPanelView 不读 hasPairing）—— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
