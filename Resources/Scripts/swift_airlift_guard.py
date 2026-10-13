# -*- coding: utf-8 -*-
"""「禁用通话录音走 airlift」防复发检查.

背景（用户原话）：
    「本来就强依赖 airlift 的东西敢擅自给我乱改是吧」
    「还敢说airlift依赖mac 实际上根本不依赖 只需要配对文件就行了！」
    「我们之前版本有过不过后来删了 是因为我考虑到我们自己没有什么精力再造车
     现在别人有现成的aircard-ios、airbeep项目 你自己不会参考吗！」

★ 关键更正（用户批评成立）：
    早前本仓把 airlift 误判为「传输侧在配对的 Mac 上、设备侧没有通道」，据此把
    「禁用通话录音」从 airlift 改成了走 `SandboxEscape`（bad_query）—— **那是错的**。
    事实：设备侧只需**配对文件 + LocalDevVPN 回环隧道**，就能在设备上直接驱动
    AirTraffic（现成实现见 `mak5er/AirCard-iOS` 的 `rust-core/` 与
    `LinkPass888/AirBeep`）。本仓已把该实现（Rust `libairlift_ffi.a`）移植进来。

本脚本是「以后不会再有人把它改回 bad_query / 也不会再写回『依赖 Mac』」的守门人，
在提交前拦住.

检查规则：
  R1  [ERROR] `EscapeOS/Engine/Airlift/` 必需文件缺失（传输层 / 日志 / 配对解析 / 版本门 /
              GrappaHelper 头与实现）.
  R2  [ERROR] `AirliftToneTransport.swift` 未调用某个必需 FFI 符号
              （al_exploit_read_file / al_exploit_write_dir / al_set_target_host / al_bytes_free）.
  R3  [ERROR] 传输层**代码**写死目标主机 `"10.7.0.1"`（必须走 `LocalDevVPN.targetIP`）.
  R4  [ERROR] `AirLiftExploit.swift`（含 `AirLiftService`）**代码**仍经 `SandboxEscape`
              （airlift 必须走 AirliftFFI，不得退回 bad_query）.
  R5  [ERROR] `CallRecordingToneService.swift` **代码**仍经 `SandboxEscape` / 仍用
              `AVAudioFile` 现生成静音（应经 `AirLiftService` + bundle 内等长静音素材）.
  R6  [ERROR] `CallRecordingToneService.swift` 缺「写后读回校验」（verificationFailed）.
  R7  [ERROR] 全仓注释/文案重新出现「依赖 Mac」类错误结论
              （「配对 Mac 的 AirTraffic」/「没有 Mac 传输通道」）.
  R8  [ERROR] `AirLiftExploit.swift` / `ExploitKind.swift` 缺「不依赖 Mac」的正面陈述.
  R9  [ERROR] 静音素材缺失（Resources/SilentTones/AirBeepStartSilence.m4a /
              AirBeepStopSilence.caf）.
  R10 [ERROR] `project.yml` 未声明 `rust-libs/AirliftFFI.xcframework` 依赖.
  R11 [ERROR] `build-xcode.yml` 未在 xcodegen 之前编 / 校验 AirliftFFI
              （build-airlift-xcframework.sh / verify-airlift.sh）.
  R12 [ERROR] 桥接头未引入 `Airlift/GrappaHelper.h`.

误报处理：匹配前先剥离**注释**（保留字符串字面量与换行，行号不错位）——
R3/R4/R5 要抓的是**实际代码**；而注释里解释「为什么不该写死 10.7.0.1」「早前误判依赖 Mac」
属正常说明，不该误报.

用法：
    python swift_airlift_guard.py [仓库根，默认 .]
    仓库根 = 含 EscapeOS/ 的那一层（即 P1_EscapeOS_宿主仓库）
退出码：0 = 全部通过；1 = 有 ERROR；2 = 参数/路径错误。
"""
import os
import re
import sys

AIRLIFT_DIR = os.path.join("EscapeOS", "Engine", "Airlift")
TRANSPORT_REL = os.path.join(AIRLIFT_DIR, "AirliftToneTransport.swift")
AIRLIFT_EXPLOIT_REL = os.path.join("EscapeOS", "Engine", "Exploits", "AirLiftExploit.swift")
EXPLOIT_KIND_REL = os.path.join("EscapeOS", "Engine", "ExploitKind.swift")
TONE_SERVICE_REL = os.path.join("EscapeOS", "Engine", "CallRecordingToneService.swift")
BRIDGING_REL = os.path.join("EscapeOS", "Engine", "EscapeOS-Bridging-Header.h")
SILENT_TONES_DIR = os.path.join("Resources", "SilentTones")
PROJECT_YML_REL = "project.yml"
WORKFLOW_REL = os.path.join(".github", "workflows", "build-xcode.yml")

REQUIRED_AIRLIFT_FILES = [
    "AirliftToneTransport.swift",
    "AirliftLog.swift",
    "AirliftPairing.swift",
    "AirliftSystemCompatibility.swift",
    "GrappaHelper.h",
    "GrappaHelper.m",
]

REQUIRED_FFI_SYMBOLS = [
    "al_exploit_read_file",
    "al_exploit_write_dir",
    "al_set_target_host",
    "al_bytes_free",
]

REQUIRED_SILENT_TONES = [
    "AirBeepStartSilence.m4a",
    "AirBeepStopSilence.caf",
]

# R7：错误结论的**具体措辞**（正面陈述「不依赖 Mac」不算命中）.
WRONG_MAC_CLAIMS = (
    "配对 Mac 的 AirTraffic",
    "没有 Mac 传输通道",
    "传输侧在配对的 Mac 上",
)

# R7 的**同一行否定标记**：若该行本身就是在纠正 / 声明旧结论作废，则不算命中
# （如「早前本仓**误判**……那是错的」）。要抓的是「又把错误结论当事实写回去」.
NEGATION_MARKERS = ("不依赖", "误判", "作废", "那是错的", "不再", "并非", "不是")

HARDCODED_HOST_LITERAL = '"10.7.0.1"'


def strip_comments(src):
    """把注释替换成等长空格（保留换行与字符串字面量），行号不错位.

    保留字符串字面量：R3 要抓的 `"10.7.0.1"` 正是出现在字符串里.
    注释里提到这些词（如解释「为什么不该写死」）属正常说明，不该误报.
    """
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
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


def check_required_files(root):
    """R1：Airlift/ 必需文件齐备."""
    findings = []
    for name in REQUIRED_AIRLIFT_FILES:
        rel = os.path.join(AIRLIFT_DIR, name).replace("\\", "/")
        if not os.path.isfile(os.path.join(root, AIRLIFT_DIR, name)):
            findings.append(("R1", "缺少 %s —— Airlift 移植件不完整." % rel))
    return findings


def check_transport_symbols(root):
    """R2/R3：传输层必须调全部 FFI 符号，且不得写死目标主机."""
    findings = []
    path = os.path.join(root, TRANSPORT_REL)
    if not os.path.isfile(path):
        return findings  # R1 已报
    code = strip_comments(read(path))
    for symbol in REQUIRED_FFI_SYMBOLS:
        if symbol not in code:
            findings.append(("R2", "%s 未调用 FFI 符号 %s —— 传输层不完整." % (
                TRANSPORT_REL.replace("\\", "/"), symbol)))
    if HARDCODED_HOST_LITERAL in code:
        findings.append(("R3", "%s 写死了目标主机 %s —— 必须走 LocalDevVPN.targetIP"
                               "（与本仓 AFC / RSD 隧道同一来源）." % (
                                   TRANSPORT_REL.replace("\\", "/"), HARDCODED_HOST_LITERAL)))
    return findings


def check_no_sandbox_escape(root, rel, label, rule):
    """R4/R5：某文件的实际代码不得再经 SandboxEscape（bad_query）."""
    findings = []
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        findings.append((rule, "找不到 %s（%s）." % (rel.replace("\\", "/"), label)))
        return findings
    code = strip_comments(read(path))
    if "SandboxEscape" in code:
        findings.append((rule, "%s 仍经 SandboxEscape（bad_query）—— %s 必须走 AirliftFFI." % (
            rel.replace("\\", "/"), label)))
    return findings


def check_tone_service(root):
    """R5/R6：通话录音服务必须经 airlift + 有写后读回校验 + 不再用 AVFoundation 现生成."""
    findings = []
    path = os.path.join(root, TONE_SERVICE_REL)
    if not os.path.isfile(path):
        findings.append(("R5", "找不到 %s." % TONE_SERVICE_REL.replace("\\", "/")))
        return findings
    code = strip_comments(read(path))
    if "AirLiftService" not in code:
        findings.append(("R5", "%s 未调用 AirLiftService —— 必须经 airlift 读 / 写." % (
            TONE_SERVICE_REL.replace("\\", "/"))))
    if "AVAudioFile" in code or "AVAudioPCMBuffer" in code:
        findings.append(("R5", "%s 仍在用 AVFoundation 现生成静音 —— 应改用 bundle 内"
                               "等长静音素材（Resources/SilentTones/）." % (
                                   TONE_SERVICE_REL.replace("\\", "/"))))
    if "verificationFailed" not in code:
        findings.append(("R6", "%s 缺「写后读回校验」—— 写入后必须读回比对." % (
            TONE_SERVICE_REL.replace("\\", "/"))))
    return findings


def check_wrong_mac_claims(root):
    """R7：全仓不得再把「依赖 Mac」类错误结论**当事实**写回（纠正性表述不算）."""
    findings = []
    base = os.path.join(root, "EscapeOS")
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            if not name.endswith((".swift", ".m", ".h", ".mm")):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            try:
                lines = read(full).splitlines()
            except OSError:
                continue
            for idx, line in enumerate(lines, 1):
                if any(marker in line for marker in NEGATION_MARKERS):
                    continue
                for claim in WRONG_MAC_CLAIMS:
                    if claim in line:
                        findings.append(("R7", "%s:%d 出现错误结论「%s」—— airlift **不依赖 Mac**，"
                                               "只需配对文件 + LocalDevVPN." % (rel, idx, claim)))
                        break
    return findings


def check_positive_statements(root):
    """R8：airlift 文件必须正面陈述「不依赖 Mac」."""
    findings = []
    for rel in (AIRLIFT_EXPLOIT_REL, EXPLOIT_KIND_REL):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            continue
        if "不依赖 Mac" not in read(path):
            findings.append(("R8", "%s 缺「不依赖 Mac」的正面陈述 —— 防再次被误判." % (
                rel.replace("\\", "/"))))
    return findings


def check_silent_tones(root):
    """R9：静音素材齐备."""
    findings = []
    for name in REQUIRED_SILENT_TONES:
        if not os.path.isfile(os.path.join(root, SILENT_TONES_DIR, name)):
            findings.append(("R9", "缺少静音素材 %s —— bundle 内等长静音不完整." % (
                os.path.join(SILENT_TONES_DIR, name).replace("\\", "/"))))
    return findings


def check_project_yml(root):
    """R10：project.yml 必须声明 AirliftFFI 依赖."""
    findings = []
    path = os.path.join(root, PROJECT_YML_REL)
    if not os.path.isfile(path):
        findings.append(("R10", "找不到 %s." % PROJECT_YML_REL))
        return findings
    if "rust-libs/AirliftFFI.xcframework" not in read(path):
        findings.append(("R10", "%s 未声明 rust-libs/AirliftFFI.xcframework 依赖 —— "
                               "`import AirliftFFI` 会编译失败." % PROJECT_YML_REL))
    return findings


def check_workflow(root):
    """R11：CI 必须在 xcodegen 之前编 / 校验 AirliftFFI."""
    findings = []
    path = os.path.join(root, WORKFLOW_REL)
    if not os.path.isfile(path):
        findings.append(("R11", "找不到 %s." % WORKFLOW_REL.replace("\\", "/")))
        return findings
    text = read(path)
    for script in ("build-airlift-xcframework.sh", "verify-airlift.sh"):
        if script not in text:
            findings.append(("R11", "%s 未引用 %s —— 未在 xcodegen 前现场编 / 校验 AirliftFFI." % (
                WORKFLOW_REL.replace("\\", "/"), script)))
    return findings


def check_bridging_header(root):
    """R12：桥接头必须引入 GrappaHelper.h."""
    findings = []
    path = os.path.join(root, BRIDGING_REL)
    if not os.path.isfile(path):
        findings.append(("R12", "找不到 %s." % BRIDGING_REL.replace("\\", "/")))
        return findings
    text = read(path)
    if not re.search(r'#\s*(?:include|import)\s+"Airlift/GrappaHelper\.h"', text):
        findings.append(("R12", "%s 未引入 Airlift/GrappaHelper.h —— Grappa 令牌生成不会编进 App." % (
            BRIDGING_REL.replace("\\", "/"))))
    return findings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."

    if not os.path.isdir(os.path.join(root, "EscapeOS")):
        print("仓库根下找不到 EscapeOS/ ：%s" % os.path.abspath(root))
        print("用法: python swift_airlift_guard.py [仓库根]")
        return 2

    findings = []
    findings += check_required_files(root)
    findings += check_transport_symbols(root)
    findings += check_no_sandbox_escape(root, AIRLIFT_EXPLOIT_REL, "AirLiftService", "R4")
    findings += check_tone_service(root)
    findings += check_wrong_mac_claims(root)
    findings += check_positive_statements(root)
    findings += check_silent_tones(root)
    findings += check_project_yml(root)
    findings += check_workflow(root)
    findings += check_bridging_header(root)

    for rule, msg in findings:
        print("ERROR %s  %s" % (rule, msg))

    print("-" * 72)
    print("检查：禁用通话录音走 airlift（移植件齐备 / FFI 符号 / 目标主机自适应 / "
          "不经 bad_query / 写后校验 / 无「依赖 Mac」错误结论 / 静音素材 / 工程与 CI 接线）")
    print("命中: %d" % len(findings))
    if not findings:
        print("✓ Airlift 移植件齐备、传输层调全 FFI 符号、目标主机走 LocalDevVPN、"
              "通话录音服务经 airlift 且写后校验、无「依赖 Mac」错误结论、"
              "静音素材与工程 / CI 接线齐备 —— 合规")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
