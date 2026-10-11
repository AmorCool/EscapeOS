# -*- coding: utf-8 -*-
"""隧道「跳转目标」（Surge / Loon）防复发检查.

背景（用户原话）：
    「https://github.com/suversal/WrapPin项目支持了Surge、Loon方式的隧道连接 我们也加上支持」

照 WrapPin 的做法，Surge / Loon 与 Shadowrocket 同口径 —— **只作跳转目标**：
不建隧道、不声称已连接，`start()` 用各自官方 URL Scheme 请求目标应用启动隧道，
随后由调用方继续检测设备通道. 关键取证：
  · Surge 官方 URL Scheme 文档（manual.nssurge.com/tools/url-scheme.html）：
    iOS 上 `surge:///start` = 「以当前配置启动」. **注意是三斜杠 `surge:///`** ——
    这是本脚本要守住的头号陷阱：`surge://start`（两斜杠）不是官方动作，写错会静默失败.
  · Loon 官方 URL Scheme 文档（nsloon.app/docs/Scheme）：`loon://on` = 「开启 VPN」.

本脚本是「以后不会再有人把 scheme 写错、把白名单删掉、把 case 漏接」的守门人.

检查范围：
  · `EscapeOS/Engine/TunnelProvider.swift`
  · `Resources/Info.plist` 的 `LSApplicationQueriesSchemes` 数组

检查规则：
  G1 [ERROR] `enum TunnelKind` 缺少 `case surge` 或 `case loon` —— 选项没接上.
  G2 [ERROR] 找不到 `URL(string: "surge:///start")` —— Surge scheme 写错或丢失（**必须是三斜杠**）.
  G3 [ERROR] 找不到 `URL(string: "loon://on")` —— Loon scheme 写错或丢失.
  G4 [ERROR] `TunnelManager.provider(for:)` 未把 `.surge` / `.loon` 映射到 `JumpTargetTunnel` —— case 漏接.
  G5 [ERROR] `Resources/Info.plist` 的 `LSApplicationQueriesSchemes` 不含 `surge` 或 `loon` —— 白名单登记缺失.

误报处理：匹配前**只剥离注释**（保留字符串字面量 —— G2/G3 要查的正是字符串里的 scheme）.
剥离用逐字符状态机，正确区分「字符串里的 `//`」（如 `"surge:///start"`）与真正的注释.

用法：
    python swift_tunnel_jump_target_guard.py [仓库根，默认 .]
    仓库根 = 含 EscapeOS/ 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有 ERROR；2 = 参数/路径错误。
"""
import os
import re
import sys

SWIFT_REL = os.path.join("EscapeOS", "Engine", "TunnelProvider.swift")
PLIST_REL = os.path.join("Resources", "Info.plist")

SURGE_SCHEME = "surge:///start"
LOON_SCHEME = "loon://on"


def strip_comments_only(src):
    """只把**注释**替换成等长空格（保留字符串字面量与换行）.

    逐字符状态机：进入双引号字符串后，其中的 `//` / `/*` 都是普通字符（关键：
    `"surge:///start"` 里的 `//` 不能当注释），直到未转义的 `"` 才退出字符串.
    块注释不嵌套. 行号不错位.
    """
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        # 字符串字面量：原样保留，跳过（含转义）
        if ch == '"':
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
        i += 1
    return "".join(out)


def find_type_body(stripped, name):
    """取 `struct/class/enum/func <name>` 的 `{...}` 体（花括号配对）."""
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
                return stripped[brace:j + 1]
    return None


def check_swift(src):
    findings = []
    code = strip_comments_only(src)

    # G1：enum TunnelKind 必须含 case surge / case loon
    kind_body = find_type_body(code, "TunnelKind")
    if kind_body is None:
        findings.append(("G1", "找不到 enum TunnelKind（应定义在 %s）." % SWIFT_REL))
    else:
        for name in ("surge", "loon"):
            if not re.search(r'\bcase\s+' + name + r'\b', kind_body):
                findings.append(("G1", "TunnelKind 缺少 `case %s` —— 选项没接上." % name))

    # G2/G3：两个官方 scheme 必须逐字存在（Surge 必须三斜杠）
    if ('URL(string: "%s")' % SURGE_SCHEME) not in code:
        findings.append(("G2",
            "找不到 URL(string: \"%s\") —— Surge scheme 写错或丢失（**必须是三斜杠 `surge:///`**，"
            "官方 URL Scheme 文档：manual.nssurge.com/tools/url-scheme.html）." % SURGE_SCHEME))
    if ('URL(string: "%s")' % LOON_SCHEME) not in code:
        findings.append(("G3",
            "找不到 URL(string: \"%s\") —— Loon scheme 写错或丢失"
            "（官方 URL Scheme 文档：nsloon.app/docs/Scheme）." % LOON_SCHEME))

    # G4：provider(for:) 必须把 .surge / .loon 映射到 JumpTargetTunnel
    provider_body = find_type_body(code, "provider")
    if provider_body is None:
        findings.append(("G4", "找不到 TunnelManager.provider(for:) —— 无法核对 case 映射."))
    else:
        for name in ("surge", "loon"):
            pat = r'case\s+\.' + name + r'\s*:\s*return\s+JumpTargetTunnel\.' + name + r'\b'
            if not re.search(pat, provider_body):
                findings.append(("G4",
                    "provider(for:) 未把 `.%s` 映射到 `JumpTargetTunnel.%s` —— case 漏接." % (name, name)))
    return findings


def check_plist(path):
    if not os.path.isfile(path):
        return [("G5", "找不到 %s." % path)]
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r'<key>\s*LSApplicationQueriesSchemes\s*</key>\s*<array>(.*?)</array>', text, re.S)
    if not m:
        return [("G5", "Info.plist 缺少 LSApplicationQueriesSchemes 数组.")]
    schemes = re.findall(r'<string>\s*([^<]+?)\s*</string>', m.group(1))
    findings = []
    for need in ("surge", "loon"):
        if need not in schemes:
            findings.append(("G5",
                "LSApplicationQueriesSchemes 不含 %s（实为 %s）." % (need, ", ".join(schemes))))
    return findings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."

    swift_path = os.path.join(root, SWIFT_REL)
    plist_path = os.path.join(root, PLIST_REL)

    if not os.path.isfile(swift_path):
        print("找不到 %s" % swift_path)
        print("用法: python swift_tunnel_jump_target_guard.py [仓库根]")
        return 2

    try:
        src = open(swift_path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("读取失败: %s" % e)
        return 2

    findings = check_swift(src) + check_plist(plist_path)

    for rule, msg in findings:
        print("ERROR %s  [%s] %s" % (swift_path.replace("\\", "/"), rule, msg))

    print("-" * 72)
    print("检查：Surge/Loon 跳转目标（%s）与 %s" % (SWIFT_REL.replace("\\", "/"), PLIST_REL.replace("\\", "/")))
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ TunnelKind 含 surge/loon、scheme 为 surge:///start 与 loon://on、provider 已映射、白名单含两者 —— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
