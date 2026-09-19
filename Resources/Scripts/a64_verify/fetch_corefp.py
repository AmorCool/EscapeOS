#!/usr/bin/env python3
"""A-64 验证用：取 bundle 内那份 CoreFP（10.9）到本地（临时脚本）。

不重复实现 Apple CDN 的 XAR + bz2 + CPIO 解析 —— 直接复用
`Resources/Scripts/prepare.sap.py` 的 `fetch_assets()`，连带它的 sha256 校验。
这样两处的素材来源永远一致，不会漂移。

用法：  fetch_corefp.py <输出目录>
产物：  <输出目录>/CoreFP、CoreFP.icxs（以及 CommerceKit / CommerceCore，未用但一并校验）
"""
import importlib.util
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: fetch_corefp.py <输出目录>", file=sys.stderr)
        return 2

    root = pathlib.Path(__file__).resolve().parents[3]      # → 仓库根
    prep = root / "Resources/Scripts/prepare.sap.py"
    spec = importlib.util.spec_from_file_location("prepare_sap", prep)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    out = pathlib.Path(sys.argv[1])
    module.fetch_assets(out)

    for name, (size, digest) in module.ASSETS.items():
        path = out / name
        ok = module.valid_asset(path, (size, digest))
        print(f"{name:14s} size={path.stat().st_size}  sha256={'OK' if ok else '不匹配'}")
        if not ok:
            print(f"::error::{name} 校验失败", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
