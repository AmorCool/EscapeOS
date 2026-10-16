#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""防复发：本机 Anisette 的开关判据契约.

背景（2026-10-16）：`remoteFallbackReason` 曾把 `.ready` 映射成「尚未接线」文案，
导致「开关打开 → 永远走远程；开关关闭 → 反而尝试本机」，与意图完全相反。
调用方 `AnisetteProvider` 的判据是 `if let reason { 回退 } else { 试本机 }`，
所以 **只有 `.ready` 才能返回 nil**.

另外守住两条已知契约错误：
  · `end_provision_uc` 只回 `{"adi_pb_base64":…}` ⇒ Swift 侧不能按 headers 解析
  · `start_provision_uc` 回 `{"cpim_base64":…,"session":n}` ⇒ spim 是输入、cpim 是输出

退出码 0 = 合规；1 = 命中.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MANAGER = ROOT / "TequilaDash/Services/AppleAuth/OnDeviceAnisetteManager.swift"
CLIENT = ROOT / "TequilaDash/Services/AppleAuth/OnDeviceAnisetteClient.swift"

hits: list[str] = []


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8")
    except FileNotFoundError:
        hits.append(f"缺少文件：{p}")
        return ""


def check_ready_returns_nil() -> None:
    """`.ready` 分支必须 `return nil`（= 可以走本机）."""
    text = read(MANAGER)
    m = re.search(r"var remoteFallbackReason:\s*String\?\s*\{(.*?)\n    \}", text, re.S)
    if not m:
        hits.append("OnDeviceAnisetteManager：找不到 remoteFallbackReason 实现")
        return
    body = m.group(1)
    ready = re.search(r"case \.ready:\s*\n\s*return ([^\n]+)", body)
    if not ready:
        hits.append("remoteFallbackReason：缺少 case .ready 分支")
        return
    if "nil" not in ready.group(1):
        hits.append(
            "remoteFallbackReason 的 case .ready 必须 return nil（nil = 可以走本机）；"
            f"当前为 {ready.group(1).strip()}"
        )
    if re.search(r"case \.off:\s*\n\s*return nil", body):
        hits.append("remoteFallbackReason 的 case .off 不能返回 nil（开关没开必须给回退原因）")


def check_provider_gate() -> None:
    """Provider 必须先问 remoteFallbackReason，且只有 nil 才试本机."""
    text = read(ROOT / "TequilaDash/Services/AppleAuth/AnisetteProvider.swift")
    if "if let reason = OnDeviceAnisetteManager.shared.remoteFallbackReason" not in text:
        hits.append("AnisetteProvider：本机分支必须先判 remoteFallbackReason")
    if "else if let local = try? fetchAnisetteLocal()" not in text:
        hits.append("AnisetteProvider：本机取数必须放在 remoteFallbackReason == nil 的分支")


def check_end_provision_contract() -> None:
    """endProvision 不能按 headers 解析（C 层只回 adi_pb_base64）."""
    text = read(CLIENT)
    m = re.search(r"static func endProvision\((.*?)\n    \}", text, re.S)
    if not m:
        hits.append("OnDeviceAnisetteClient：找不到 endProvision")
        return
    body = m.group(1)
    if "parseHeaders" in body:
        hits.append("endProvision 不能调 parseHeaders（C 层只返回 adi_pb_base64）")
    if "adi_pb_base64" not in body:
        hits.append("endProvision 必须解析 adi_pb_base64")


def check_start_provision_contract() -> None:
    """startProvision 必须解析 cpim_base64（输入是 spim）."""
    text = read(CLIENT)
    m = re.search(r"static func startProvision\((.*?)\n    \}", text, re.S)
    if not m:
        hits.append("OnDeviceAnisetteClient：找不到 startProvision")
        return
    body = m.group(1)
    if "cpim_base64" not in body:
        hits.append("startProvision 必须解析 cpim_base64（C 层输出字段）")


def main() -> int:
    check_ready_returns_nil()
    check_provider_gate()
    check_end_provision_contract()
    check_start_provision_contract()

    print("检查：本机 Anisette 开关判据与配给契约")
    print("  · remoteFallbackReason：只有 .ready 返回 nil")
    print("  · Provider：nil 才试本机")
    print("  · endProvision：解析 adi_pb_base64")
    print("  · startProvision：解析 cpim_base64")
    if hits:
        print(f"命中: {len(hits)}")
        for h in hits:
            print("  [命中] " + h)
        return 1
    print("命中: 0")
    print("✓ 契约一致 —— 合规")
    return 0


if __name__ == "__main__":
    sys.exit(main())
