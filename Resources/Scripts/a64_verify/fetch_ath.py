#!/usr/bin/env python3
"""A-64 验证用：从 runner 自己的 macOS 上现取 AirTrafficHost（临时脚本）。

为什么要「现取」而不是从仓库拿：Apple 二进制绝不进仓库（项目铁律）。
为什么按这个顺序找：Apple Silicon 上 `/Library/Apple/...` 是给 Rosetta 用的
兼容层副本，正是**含 x86_64 切片**的那一份 —— 2026-08-13 取
`_tmp_mac/fw/A/AirTrafficHost` 时走的就是这条；`/System/Library/...` 那份
在较新的 macOS 上可能只剩共享缓存里的 arm64e。

用法：  fetch_ath.py <输出文件路径>
成功时退出码 0，并打印 sha256 + FAT 布局（供与 _gp15/A64-ASSET-HASHES.txt 对照）。

挑候选的规则：**不是「第一个存在的就用」，而是「第一个真正含 x86_64 切片的」**。
4 条固定路径全落空时，再在有界范围内兜底搜索（只下钻 AirTraffic* 目录）。
"""
import hashlib
import os
import pathlib
import shutil
import struct
import sys

CPU_TYPE_X86_64 = 0x01000007
FAT_MAGIC = b"\xca\xfe\xba\xbe"

CANDIDATES = [
    "/Library/Apple/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost",
    "/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost",
    "/Library/Apple/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
    "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
]

# 固定路径全落空时的兜底搜索根（macOS 26 的系统框架实体在 Preboot cryptex 里）。
SEARCH_ROOTS = [
    "/System/Library/PrivateFrameworks",
    "/Library/Apple/System/Library/PrivateFrameworks",
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks",
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks",
    "/System/Library/Frameworks",
    "/Library/Apple/System/Library/Frameworks",
]


def search_fallback() -> list:
    """在有界范围内找 AirTrafficHost。

    剪枝规则**只作用于根这一层**：根目录下只进名字以 `AirTraffic` 开头的目录
    —— /System/Library/PrivateFrameworks 下有一千多个 framework，全量下钻太慢。
    ⚠️ 进去之后**不能继续按名字剪**：`.framework/Versions/A/` 里的
    `Versions` 和 `A` 都不以 AirTraffic 开头，一并剪掉就永远找不到文件本体
    （这个 bug 被本地自造目录树的用例抓到过）。改成只限深度。
    """
    hits = []
    for root in SEARCH_ROOTS:
        r = pathlib.Path(root)
        if not r.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(r):
            depth = len(pathlib.Path(dirpath).relative_to(r).parts)
            if depth == 0:
                dirnames[:] = [d for d in dirnames if d.startswith("AirTraffic")]
            elif depth >= 4:
                dirnames[:] = []
            if "AirTrafficHost" in filenames:
                hits.append(pathlib.Path(dirpath) / "AirTrafficHost")
    return hits


def has_x86_slice(path: pathlib.Path) -> bool:
    """只读文件头判断有没有 x86_64 切片（不打印，用于挑候选）。"""
    try:
        with open(path, "rb") as fh:
            head = fh.read(8)
            if len(head) < 8:
                return False
            if head[:4] != FAT_MAGIC:
                _magic, cputype = struct.unpack_from("<II", head, 0)
                return cputype == CPU_TYPE_X86_64
            nfat = struct.unpack_from(">I", head, 4)[0]
            if nfat <= 0 or nfat > 64:
                return False
            table = fh.read(nfat * 20)
            for i in range(nfat):
                cputype = struct.unpack_from(">I", table, i * 20)[0]
                if cputype == CPU_TYPE_X86_64:
                    return True
    except OSError:
        return False
    return False


def describe(path: pathlib.Path) -> bool:
    """打印 FAT 布局；返回「是否含 x86_64 切片」。"""
    data = path.read_bytes()
    print(f"size   = {len(data)}")
    print(f"sha256 = {hashlib.sha256(data).hexdigest()}")
    print(f"magic  = {data[:4].hex()}")

    if data[:4] != FAT_MAGIC:
        # thin 的情况：直接看 Mach-O 头的 cputype（runner 上多数是这种）
        magic, cputype = struct.unpack_from("<II", data, 0)
        print(f"不是 fat，是 thin Mach-O：magic={magic:#x} cputype={cputype:#x}"
              f"（{'x86_64 ✓' if cputype == CPU_TYPE_X86_64 else '不是 x86_64 ✗'}）")
        return cputype == CPU_TYPE_X86_64

    nfat = struct.unpack_from(">I", data, 4)[0]
    print(f"FAT nfat={nfat}")
    have_x86 = False
    for i in range(nfat):
        off = 8 + i * 20
        cputype, cpusub, offset, size, _align = struct.unpack_from(">iiIII", data, off)
        cputype &= 0xFFFFFFFF
        print(f"  slice{i} cputype={cputype:#x} cpusub={cpusub & 0xFFFFFFFF:#x} "
              f"offset={offset} size={size}")
        if cputype == CPU_TYPE_X86_64:
            have_x86 = True
    print(f"含 x86_64 切片: {have_x86}")
    return have_x86


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: fetch_ath.py <输出文件路径>", file=sys.stderr)
        return 2

    dest = pathlib.Path(sys.argv[1])
    dest.parent.mkdir(parents=True, exist_ok=True)

    # 逐个候选试：**必须挑到含 x86_64 切片的那一份**。
    # 为什么不是「第一个存在的就用」：macOS 26 上 /System/Library/... 那份可能
    # 存在但只剩 arm64e（x86_64 只活在共享缓存里），先撞上它就白跑一轮 CI。
    checked = []
    chosen = None
    for candidate in CANDIDATES:
        path = pathlib.Path(candidate)
        if not path.is_file():
            print(f"不存在：{candidate}")
            continue
        if has_x86_slice(path):
            print(f"命中（含 x86_64 切片）：{candidate}")
            chosen = path
            break
        print(f"存在但无 x86_64 切片：{candidate}")
        checked.append(str(path))

    if chosen is None:
        found = search_fallback()
        for path in found:
            if has_x86_slice(path):
                print(f"命中（兜底搜索，含 x86_64 切片）：{path}")
                chosen = path
                break
            print(f"兜底搜索到但无 x86_64 切片：{path}")
            checked.append(str(path))
        if chosen is None and found:
            print(f"兜底搜索到 {len(found)} 份 AirTrafficHost，但都没有 x86_64 切片")

    if chosen is None:
        print("::error::runner 上找不到含 x86_64 切片的 AirTrafficHost —— A-64 跑不了", file=sys.stderr)
        if checked:
            print(f"::error::以下是存在但没有 x86_64 切片的：{' / '.join(checked)}", file=sys.stderr)
            print("::error::说明本机 ATH 只剩 arm64e，x86_64 片可能在 dyld 共享缓存里，"
                  "需先用 dyld_shared_cache_util 抽取", file=sys.stderr)
        else:
            print("::error::4 条固定路径 + 兜底搜索都没找到文件本体；"
                  "请确认这台 runner 的 macOS 版本里是否还带 AirTrafficHost", file=sys.stderr)
        return 1

    shutil.copy2(chosen, dest)
    print("=== 素材指纹（与 _gp15/A64-ASSET-HASHES.txt 对照）===")
    if not describe(dest):
        print("::error::这份 AirTrafficHost 没有 x86_64 切片，A-64 跑不了", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
