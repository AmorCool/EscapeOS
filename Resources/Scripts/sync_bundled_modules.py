#!/usr/bin/env python3
"""把 module-esc 里的模块同步进宿主：① 内置模块清单 ② 所有模块的原生 UI 源码.

## 为什么要有这个脚本（而不是在 workflow 里写死）

`BundledModules/` 里的模块会在首次启动时被 `ModuleService.bootstrapBundledModules()`
自动安装 —— 也就是「内置模块」，用户看到的是已经装好的卡片、卸载后不会再回来。

而模块仓库里的模块**默认应该是独立的**（走 edge Release 的 .zip 按需导入）。
所以「哪些内置」必须由**模块自己声明**，不能靠 CI 里硬编码。

v0.3.481 真机踩到的坑：旧实现是 `cp -R _module-esc/modules/*` + 硬编码
`rm -rf .../com.escapeos.alist`，于是新加的模块被自动打包成了内置模块
（而那个模块用户明确要求它是独立的）。而且每加一个不内置的模块都要回来改一次 workflow ——
典型的「为模块适配构建脚本」。

## 规则

`module.json` 的 `distribution` 字段：

| 值 | 含义 |
|---|---|
| `bundled` | 内置进 app（随包发布，首次启动自动安装） |
| `external`（**默认**） | 独立模块，走 edge Release 的 .zip 按需导入 |

默认取 `external` 是刻意的：**「不内置」是安全的默认值** —— 忘了写字段时，
模块不会被悄悄塞进 app。

## v0.3.505：原生 UI 源码也由模块仓库拥有

用户的意见：「模块没真正独立，SwiftUI 界面得集成在模块里，而不是散在宿主仓库」.

**为什么不能把 UI 放进模块 .zip 让宿主运行时加载**：SwiftUI 视图必须**编译**，
而设备上没有 Swift 编译器；zip 里放 .swift 源文件没有任何运行时作用.
（宿主的 `ModuleUIRegistry` 头注释写的就是这件事.）

**所以采取的折中**：UI **源码**放进模块仓库的 `modules/<id>/ui/`，
本脚本在 **xcodegen 之前**把它拷到 `EscapeOS/Modules/<id>/`，
于是宿主编译时自然带上 —— 模块仓库成为 UI 的唯一数据源，宿主仓库不再持有副本.

代价：改 UI 仍需**重编宿主**（做不到热更新）. 要热更新只能走 `webroot`（HTML）那条路.

## 用法

    python3 Resources/Scripts/sync_bundled_modules.py <module-esc 克隆目录> [目标目录]

目标目录默认 `Resources/BundledModules`（相对仓库根，脚本会自己找根）。
⚠️ **本地开发也要跑一次**，否则 `EscapeOS/Modules/` 是空的、
内置模块的原生界面符号找不到、编译失败.

退出码：0 成功；1 参数/IO 错误。
"""

import json
import os
import shutil
import sys


def repo_root() -> str:
    """脚本在 Resources/Scripts/ 下，仓库根是上两级."""
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def sync_ui_sources(src_root: str, root: str) -> list:
    """把每个模块 `ui/` 下的 .swift 拷到 `EscapeOS/Modules/<id>/`.

    ## 为什么要**先清空再拷**
    模块改名 / 删文件后，旧副本会留在宿主源码树里继续参与编译 ——
    那是最难查的一类「幽灵编译错误」. 所以每个模块目录整体重建.
    """
    dst_root = os.path.join(root, "EscapeOS", "Modules")
    os.makedirs(dst_root, exist_ok=True)

    synced = []
    for mid in sorted(os.listdir(src_root)):
        src_ui = os.path.join(src_root, mid, "ui")
        dst_ui = os.path.join(dst_root, mid)
        if not os.path.isdir(src_ui):
            # 该模块没有原生 UI（webroot / 无界面）—— 清掉可能存在的旧副本
            if os.path.isdir(dst_ui):
                shutil.rmtree(dst_ui)
                print(f"  − 已移除 {mid} 的旧 UI 源码副本（模块里已无 ui/）")
            continue
        if os.path.isdir(dst_ui):
            shutil.rmtree(dst_ui)
        os.makedirs(dst_ui, exist_ok=True)
        # 只拷 .swift —— ui/ 里的 README.md 之类**不能**进宿主源码树：
        #   它们会被当资源拷进 .app 根目录，两个同名 README 直接报
        #   「Multiple commands produce .../EscapeSpace.app/README.md」（v0.3.506 实锤）.
        count = 0
        for f in sorted(os.listdir(src_ui)):
            if not f.endswith(".swift"):
                continue
            shutil.copy2(os.path.join(src_ui, f), os.path.join(dst_ui, f))
            count += 1
        synced.append(f"{mid}({count} 个 .swift)")

    # 反向清理：宿主里已有、但模块仓库里已经不存在的模块目录
    for existing in sorted(os.listdir(dst_root)):
        full = os.path.join(dst_root, existing)
        if not os.path.isdir(full):
            continue
        if not os.path.isdir(os.path.join(src_root, existing)):
            shutil.rmtree(full)
            print(f"  − 已移除 {existing} 的 UI 源码（模块仓库里已无此模块）")

    return synced


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    src_root = os.path.join(sys.argv[1], "modules")
    if not os.path.isdir(src_root):
        print(f"找不到模块目录: {src_root}")
        return 1

    root = repo_root()
    dst_root = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "Resources", "BundledModules")
    os.makedirs(dst_root, exist_ok=True)

    bundled, external, skipped = [], [], []

    for mid in sorted(os.listdir(src_root)):
        src = os.path.join(src_root, mid)
        manifest = os.path.join(src, "module.json")
        if not os.path.isfile(manifest):
            skipped.append(mid)
            continue
        try:
            with open(manifest, encoding="utf-8") as fh:
                meta = json.load(fh)
        except Exception as exc:
            print(f"  ⚠ {mid} 的 module.json 解析失败（{exc}），跳过")
            skipped.append(mid)
            continue

        dist = meta.get("distribution", "external")
        if dist != "bundled":
            external.append(f"{mid}({dist})")
            continue

        target = os.path.join(dst_root, mid)
        if os.path.isdir(target):
            shutil.rmtree(target)
        shutil.copytree(src, target)
        bundled.append(mid)

    # 反向清理：目标目录里已有、但这次不再属于内置的模块要删掉 ——
    # 否则「把某模块从内置改成独立」之后，旧副本会一直留在 app 里。
    for existing in sorted(os.listdir(dst_root)):
        full = os.path.join(dst_root, existing)
        if not os.path.isdir(full) or existing in bundled:
            continue
        if existing == "__pycache__":
            continue
        shutil.rmtree(full)
        print(f"  − 已从 BundledModules 移除 {existing}（不再是内置模块）")

    ui = sync_ui_sources(src_root, root)

    print(f"内置模块 ({len(bundled)}): {bundled or '（无）'}")
    print(f"独立模块 ({len(external)}): {external or '（无）'}")
    print(f"原生 UI 源码 ({len(ui)}): {ui or '（无）'}")
    if skipped:
        print(f"跳过（无 module.json）: {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
