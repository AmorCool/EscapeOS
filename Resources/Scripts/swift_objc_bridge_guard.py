#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""防复发：ObjC 桥接调用口径 + ForEach 身份键 + ObjC 选择器歧义.

背景（2026-10-16）：
  · CI run 38900630319：`TunnelContext.shared()` —— ObjC 类属性
    （`@property (class, readonly)`）在 Swift 侧是**属性**，不带括号.
  · CI run 38902492908：`TunnelContext.m:82:23: error: expected ':'` ——
    `[self _handleLock lock]` 被 clang 解析成多段选择器（`_handleLock:` + `lock:`），
    因为 `_handleLock` 是 ivar 但以 `_` 开头，clang 优先当选择器首段.
  · 同类第二坑：Swift 的 **key path 不能指向元组成员**，
    `ForEach(tupleArray, id: \\.name)` 无法编译 ⇒ 诊断用的接口列表必须是结构体.

判据：
  R1 ObjC 桥接类不得以 `.shared()` 形式调用（应为属性 `.shared`）.
  R2 `allInterfaces()` 必须返回结构体数组（非元组）.
  R3 ObjC 里不得出现 `[self _ivar method]` 两段式（应写 `[_ivar method]` 或 `self->_ivar`）.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SWIFT_DIR = ROOT / "TequilaDash"

hits: list[str] = []


def swift_files() -> list[Path]:
    return sorted(SWIFT_DIR.rglob("*.swift"))


def objc_files() -> list[Path]:
    out: list[Path] = []
    for ext in ("*.m", "*.mm", "*.h"):
        out.extend(sorted(SWIFT_DIR.rglob(ext)))
    return out


def check_shared_property() -> None:
    """R1：ObjC 类属性不得写成 .shared()（PHPhotoLibrary 等 Swift 类除外）."""
    allowed = {"PHPhotoLibrary", "FileManager", "NotificationCenter", "URLSession"}
    for p in swift_files():
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            m = re.search(r"(\w+)\.shared\(\)", line)
            if not m:
                continue
            if m.group(1) in allowed:
                continue
            hits.append(
                f"{p.relative_to(ROOT)}:{i} —— `{m.group(1)}.shared()`："
                "若是 ObjC 类属性（@property (class, readonly)）应写 `.shared`（无括号）"
            )


def check_tuple_keypath() -> None:
    """R2：`allInterfaces()` 必须返回结构体数组（元组不支持 key path）."""
    dev = SWIFT_DIR / "Engine/LocalDevVPN.swift"
    text = dev.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"static func allInterfaces\(\)\s*->\s*([^\n{]+)", text)
    if not m:
        hits.append("LocalDevVPN：找不到 allInterfaces() 声明")
        return
    ret = m.group(1).strip()
    if ret.startswith("[" ) and ":" in ret and "(" in ret:
        hits.append(
            f"LocalDevVPN.allInterfaces() 返回元组数组（{ret}）—— "
            "Swift key path 不能指向元组成员，ForEach 无法编译；请改用结构体"
        )


def check_selector_ambiguity() -> None:
    """R3：ObjC 里 `[self _ivar method]` 会被当多段选择器 ⇒ 报 expected ':'."""
    for p in objc_files():
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            # 形如 [self _foo bar] / [self _foo bar:...] —— receiver 后紧跟 _ivar 再跟一个词
            m = re.search(r"\[\s*self\s+(_\w+)\s+(\w+)", line)
            if m:
                hits.append(
                    f"{p.relative_to(ROOT)}:{i} —— `[self {m.group(1)} {m.group(2)}]`："
                    f"clang 会把 `{m.group(1)}` 当选择器首段并报 expected ':'；"
                    f"应写 `[{m.group(1)} {m.group(2)}]` 或 `[self->{m.group(1)} {m.group(2)}]`"
                )


def main() -> int:
    check_shared_property()
    check_tuple_keypath()
    check_selector_ambiguity()

    print("检查：ObjC 桥接调用口径 + ForEach 身份键 + ObjC 选择器歧义")
    print("  · R1 ObjC 类属性不写成 .shared()")
    print("  · R2 allInterfaces() 返回结构体数组（非元组）")
    print("  · R3 ObjC 不写 `[self _ivar method]`（会被当多段选择器）")
    if hits:
        print(f"命中: {len(hits)}")
        for h in hits:
            print("  [命中] " + h)
        return 1
    print("命中: 0")
    print("✓ 调用口径一致 —— 合规")
    return 0


if __name__ == "__main__":
    sys.exit(main())
