# -*- coding: utf-8 -*-
"""隧道可用性门控检查 —— 防复发机制.

背景（用户原话）：
    「那个更多-设置里的隧道连接 那个shadowrocket连接方式还是没有检测到 为什么你localdev就能检测到」

根因（真机取证，2026-10-11，iPhone 11 / iPhone12,1 / iOS 26.0.1 / Build 23A355）：
  · `LocalDevVPNTunnel.availability` 恒 `.available` —— 它**根本不检测**，所以「能检测到」是假象；
  · `ShadowrocketTunnel.availability` 却拿 `canOpenURL(shadowrocket://open)` 当门控，而
    `canOpenURL` 只回答「白名单里有该 scheme **且** 有 App 注册了它」，**不证明已安装**，
    且在 TrollStore / 越狱环境下会因 `lsd`（LaunchServices）缓存未同步而**假阴性**
    （白名单与注册都正确仍偶发 false）⇒ Shadowrocket 明明已装（2.2.90，`shadowrocket` 在其
    `CFBundleURLSchemes` 首位）却报「未检测到 Shadowrocket」.

收口方案：Shadowrocket 与 LocalDevVPN **同口径** —— `availability` 恒 `.available`、不设门槛；
「装没装」改由 `start()` 里 `open(...)` 的 completion 回调如实反馈（未受理则兜底跳 App Store）.

本脚本是「以后不会再有人把 canOpenURL 门控加回来」的守门人，在提交前拦住。

检查范围：
  · `EscapeOS/Engine/TunnelProvider.swift` 的 `ShadowrocketTunnel` 类型体
  · `Resources/Info.plist` 的 `LSApplicationQueriesSchemes` 数组

检查规则：
  R1 [ERROR] `ShadowrocketTunnel` 体内出现 `canOpenURL` —— 探测不可靠，不得用于门控.
  R2 [ERROR] `ShadowrocketTunnel` 体内出现 `isAvailable` —— 不得据此跳过跳转（availability 应恒可用）.
  R3 [ERROR] `Resources/Info.plist` 的 `LSApplicationQueriesSchemes` 不含 `shadowrocket` —— 白名单登记缺失.
  R4 [ERROR] `ShadowrocketTunnel.start()` 未使用带 completion 的 `open(...)` —— 无法如实反馈「系统是否受理」.

误报处理：匹配前**先剥离注释与字符串字面量**（注释里大量提到 `canOpenURL` / `isAvailable`，
不剥离会满屏误报）；剥离保留换行，行号不错位.

用法：
    python swift_tunnel_availability_guard.py [仓库根，默认 .]
    仓库根 = 含 EscapeOS/ 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有 ERROR；2 = 参数/路径错误。
"""
import os
import re
import sys

SWIFT_REL = os.path.join("EscapeOS", "Engine", "TunnelProvider.swift")
PLIST_REL = os.path.join("Resources", "Info.plist")

STRUCT_NAME = "ShadowrocketTunnel"
REQUIRED_SCHEME = "shadowrocket"


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


def check_swift(src):
    """返回 findings: [(rule, message)]."""
    findings = []
    stripped = strip_comments_and_strings(src)
    found = find_type_body(stripped, STRUCT_NAME)
    if found is None:
        findings.append(("R1", "找不到类型 %s（它应定义在 %s）." % (STRUCT_NAME, SWIFT_REL)))
        return findings
    body, _ = found

    # R1：不得出现 canOpenURL（探测不可靠，不得用于门控）
    if "canOpenURL" in body:
        findings.append(("R1",
            "%s 体内出现 canOpenURL —— canOpenURL 不证明已安装、且在 TrollStore/越狱下会因 lsd 缓存假阴性，"
            "不得用于门控；availability 应恒 .available." % STRUCT_NAME))

    # R2：不得出现 isAvailable（不得据此跳过跳转）
    if re.search(r'\bisAvailable\b', body):
        findings.append(("R2",
            "%s 体内出现 isAvailable —— 不得据 availability 跳过跳转（探测不可靠），start() 应无条件 open." % STRUCT_NAME))

    # R4：start() 必须用带 completion 的 open(...)
    start_body = find_type_body(body, "start")  # 复用：匹配 func start 的 {...}
    if start_body is None:
        findings.append(("R4", "%s 找不到 start() 方法体." % STRUCT_NAME))
    else:
        sb, _ = start_body
        if not re.search(r'\.open\([^;{}]*\)\s*\{', sb):
            findings.append(("R4",
                "%s.start() 未使用带 completion 的 open(...) —— 无法如实反馈「系统是否受理」，"
                "应写 open(url, options:) { accepted in ... } 并在未受理时兜底跳 App Store." % STRUCT_NAME))
    return findings


def check_plist(path):
    """返回 findings: [(rule, message)]."""
    if not os.path.isfile(path):
        return [("R3", "找不到 %s." % path)]
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r'<key>\s*LSApplicationQueriesSchemes\s*</key>\s*<array>(.*?)</array>', text, re.S)
    if not m:
        return [("R3", "Info.plist 缺少 LSApplicationQueriesSchemes 数组.")]
    schemes = re.findall(r'<string>\s*([^<]+?)\s*</string>', m.group(1))
    if REQUIRED_SCHEME not in schemes:
        return [("R3", "LSApplicationQueriesSchemes 不含 %s（实为 %s）." % (REQUIRED_SCHEME, ", ".join(schemes)))]
    return []


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."

    swift_path = os.path.join(root, SWIFT_REL)
    plist_path = os.path.join(root, PLIST_REL)

    if not os.path.isfile(swift_path):
        print("找不到 %s" % swift_path)
        print("用法: python swift_tunnel_availability_guard.py [仓库根]")
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
    print("检查：%s（%s）与 %s" % (STRUCT_NAME, SWIFT_REL.replace("\\", "/"), PLIST_REL.replace("\\", "/")))
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ Shadowrocket 可用性不依赖 canOpenURL、白名单含 shadowrocket、start() 带受理回调 —— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
