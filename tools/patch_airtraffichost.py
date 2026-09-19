#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阶段 1：从 macOS AirTrafficHost.framework 的 FAT 通用二进制里抽出 arm64e 切片，
打成可以在 iOS 上加载的薄 Mach-O，并做两处补丁：
  A. LC_BUILD_VERSION.platform  macOS(1) -> iOS(2)，minos -> 18.0
  B. LC_LOAD_DYLIB MobileDevice 路径 -> @executable_path/libMobileDeviceStub.dylib
最后枚举"从 MobileDevice 导入的符号"（走 LC_DYLD_CHAINED_FIXUPS 的 import 表，
比只看 SYMTAB 更准，因为 SYMTAB 不区分符号来自哪个 dylib）。

产物全部落在 _tmp_fw/。
"""
import os
import struct
import sys

# 桩 dylib 在 .app 里的落点由 project.yml 决定：
# 它必须是一个真正的 Xcode target（dynamicLibrary），而 xcodegen 的 `embed: true`
# 只会把产物拷进 `.app/Frameworks/`（没有别的可选目录），
# 所以 LC_LOAD_DYLIB 里必须写成 `@executable_path/Frameworks/libMobileDeviceStub.dylib`。
# （lead 原话是 `@executable_path/libMobileDeviceStub.dylib`，即桩放 .app 根 —— 那样
#  只能靠 post-build 脚本再拷一份到根目录，多一份签名副本、更容易出错，故改成 Frameworks/。
#  想切回原写法：本脚本加 `--stub-path @executable_path/libMobileDeviceStub.dylib` 即可。）
def _opt(name, default):
    """极简取参：`--name value`。不引 argparse，少一个依赖。"""
    for i, a in enumerate(sys.argv):
        if a == name and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


STUB_PATH = _opt("--stub-path",
                 "@executable_path/Frameworks/libMobileDeviceStub.dylib").encode()

# ---- 输入：macOS 的 AirTrafficHost（FAT 通用二进制）----
# ★ 默认值就是 macOS 系统里的**真实路径**：CI 的 `macos-latest` runner 上直接可取。
#   所以**这个二进制不需要进仓库** —— 避免把 Apple 的专有代码再分发到公开仓库里。
#   本地想跑就 `--src <本机解包出来的路径>`。
SRC = _opt("--src",
           "/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost")

# ---- 输出 ----
# `--out` 指定最终那个「能在 iOS 上加载的薄 arm64e Mach-O」的**完整落盘路径**
# （CI 里直接写 `$APP/Frameworks/AirTrafficHost`）；`--outdir` 放辅助产物
# （`mobiledevice-imports.txt` / `PATCH-REPORT.txt` / 未补丁的 `.orig`）。
OUTDIR = _opt("--outdir", os.path.join(os.getcwd(), "_fw_out"))
OUT_FILE = _opt("--out", os.path.join(OUTDIR, "AirTrafficHost"))
os.makedirs(OUTDIR, exist_ok=True)
_out_parent = os.path.dirname(os.path.abspath(OUT_FILE))
if _out_parent:
    os.makedirs(_out_parent, exist_ok=True)

MH_MAGIC_64 = 0xFEEDFACF
LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_BUILD_VERSION = 0x32
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_CODE_SIGNATURE = 0x1D

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2

# 注意：下面这张表的值必须与 <mach-o/loader.h> 完全一致。
# 0x24 之后每一条都容易记错一位，这里按头文件逐个核对过。
LC_NAMES = {
    0x01: "LC_SEGMENT", 0x02: "LC_SYMTAB", 0x03: "LC_SYMSEG", 0x04: "LC_THREAD",
    0x05: "LC_UNIXTHREAD", 0x06: "LC_LOADFVMLIB", 0x07: "LC_IDFVMLIB",
    0x08: "LC_IDENT", 0x09: "LC_FVMFILE", 0x0A: "LC_PREPAGE", 0x0B: "LC_DYSYMTAB",
    0x0C: "LC_LOAD_DYLIB", 0x0D: "LC_ID_DYLIB", 0x0E: "LC_LOAD_DYLINKER",
    0x0F: "LC_ID_DYLINKER", 0x10: "LC_PREBOUND_DYLIB", 0x11: "LC_ROUTINES",
    0x12: "LC_SUB_FRAMEWORK", 0x13: "LC_SUB_UMBRELLA", 0x14: "LC_SUB_CLIENT",
    0x15: "LC_SUB_LIBRARY", 0x16: "LC_TWOLEVEL_HINTS", 0x17: "LC_PREBIND_CKSUM",
    0x18: "LC_LOAD_WEAK_DYLIB", 0x19: "LC_SEGMENT_64", 0x1A: "LC_ROUTINES_64",
    0x1B: "LC_UUID", 0x1C: "LC_RPATH", 0x1D: "LC_CODE_SIGNATURE",
    0x1E: "LC_SEGMENT_SPLIT_INFO", 0x1F: "LC_REEXPORT_DYLIB", 0x20: "LC_LAZY_LOAD_DYLIB",
    0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO", 0x23: "LC_LOAD_UPWARD_DYLIB",
    0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
    0x26: "LC_FUNCTION_STARTS", 0x27: "LC_DYLD_ENVIRONMENT", 0x28: "LC_MAIN",
    0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION", 0x2B: "LC_DYLIB_CODE_SIGN_DRS",
    0x2C: "LC_ENCRYPTION_INFO_64", 0x2D: "LC_LINKER_OPTION",
    0x2E: "LC_LINKER_OPTIMIZATION_HINT", 0x2F: "LC_VERSION_MIN_TVOS",
    0x30: "LC_VERSION_MIN_WATCHOS", 0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION",
    0x33: "LC_DYLD_EXPORTS_TRIE", 0x34: "LC_DYLD_CHAINED_FIXUPS",
}

out = []          # 报告正文
def log(s=""):
    out.append(s)
    print(s)


# ---------------------------------------------------------------- FAT 解析
data = open(SRC, "rb").read()
log("== 源文件 ==")
log("  路径: %s" % SRC)
log("  大小: %d 字节" % len(data))
magic = data[:4]
assert magic == b"\xca\xfe\xba\xbe", "不是大端 FAT: %s" % magic.hex()
nfat = struct.unpack(">I", data[4:8])[0]
log("  FAT magic=cafebabe (大端)  nfat=%d" % nfat)
slices = []
for i in range(nfat):
    o = 8 + i * 20
    ct, cs, off, size, align = struct.unpack(">IIIII", data[o:o + 20])
    slices.append((ct, cs, off, size, align))
    log("  slice[%d] cputype=0x%08x cpusubtype=0x%08x off=%d size=%d align=%d" %
        (i, ct, cs, off, size, align))

# 选 arm64e（cputype 0x0100000c）。注意 cpusubtype 的高位是 CPU_SUBTYPE_LIB64/PTRAUTH 标志，
# 低 8 位才是真正的 subtype，这里低 8 位 == 2 就是 arm64e。
target = None
for i, (ct, cs, off, size, align) in enumerate(slices):
    if ct == CPU_TYPE_ARM64 and (cs & 0xFF) == CPU_SUBTYPE_ARM64E:
        target = (i, ct, cs, off, size)
        break
assert target, "FAT 里找不到 arm64e 切片"
idx, ct, cs, off, size = target
log("  选中 slice[%d] = arm64e (off=%d size=%d)" % (idx, off, size))

# 切片在文件里的字节原样搬出来就是合法薄 Mach-O：
# Mach-O 内部所有 fileoff 都是相对切片起点的，所以直接切片即可。
thin = bytearray(data[off:off + size])
assert struct.unpack("<I", thin[:4])[0] == MH_MAGIC_64, "切片开头不是 MH_MAGIC_64"
open(os.path.join(OUTDIR, "AirTrafficHost.orig"), "wb").write(bytes(thin))
log("  -> 薄切片(未补丁) %d 字节  magic=0x%08x" %
    (len(thin), struct.unpack("<I", thin[:4])[0]))


# ---------------------------------------------------------------- load commands
def parse_lcs(buf):
    ncmds, = struct.unpack_from("<I", buf, 16)
    res = []
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, p)
        res.append((p, cmd, cmdsize))
        p += cmdsize
    return res


def ver(v):
    """Mach-O 的 version 是 X.Y.Z 压进 32 位：X<<16 | Y<<8 | Z"""
    return "%d.%d.%d" % (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def lcname(cmd):
    base = cmd & ~LC_REQ_DYLD
    n = LC_NAMES.get(base, "LC_UNKNOWN(0x%x)" % cmd)
    if cmd & LC_REQ_DYLD:
        n += " [REQ_DYLD]"
    return n


lcs = parse_lcs(thin)
log()
log("== arm64e 切片 load commands (ncmds=%d) ==" % len(lcs))
for p, cmd, cmdsize in lcs:
    extra = ""
    if cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB):
        noff, = struct.unpack_from("<I", thin, p + 8)
        s = thin[p + noff:thin.index(b"\0", p + noff)].decode("utf-8", "replace")
        extra = "  name=%s" % s
    if cmd == LC_BUILD_VERSION:
        plat, minos, sdk, ntools = struct.unpack_from("<IIII", thin, p + 8)
        extra = "  platform=%d minos=0x%x(%s) sdk=0x%x(%s) ntools=%d" % (
            plat, minos, ver(minos), sdk, ver(sdk), ntools)
    if cmd in (LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS, LC_CODE_SIGNATURE):
        doff, dsize = struct.unpack_from("<II", thin, p + 8)
        extra = "  dataoff=%d datasize=%d" % (doff, dsize)
    if cmd == LC_SYMTAB:
        so, ns, sto, ss = struct.unpack_from("<IIII", thin, p + 8)
        extra = "  symoff=%d nsyms=%d stroff=%d strsize=%d" % (so, ns, sto, ss)
    log("  @0x%04x cmd=0x%08x %-24s cmdsize=%d%s" % (p, cmd, lcname(cmd), cmdsize, extra))


# ---------------------------------------------------------------- 补丁 A
log()
log("== 补丁 A: LC_BUILD_VERSION platform -> iOS ==")
bv = [(p, cmd, sz) for p, cmd, sz in lcs if cmd == LC_BUILD_VERSION]
assert len(bv) == 1, "LC_BUILD_VERSION 数量异常: %d" % len(bv)
p, cmd, sz = bv[0]
old_plat, old_minos, old_sdk, ntools = struct.unpack_from("<IIII", thin, p + 8)
log("  补丁前: platform=%d(%s) minos=0x%x(%s) sdk=0x%x(%s)" % (
    old_plat, "macOS" if old_plat == 1 else "?", old_minos, ver(old_minos), old_sdk, ver(old_sdk)))
# 注意：minos/sdk 是 X.Y.Z 压缩成 0x00XXYYZZ（X 占 16 位）。
# iOS 18.0 -> 18<<16 = 0x120000
NEW_PLAT = 2          # PLATFORM_IOS
NEW_MINOS = 0x120000  # iOS 18.0
struct.pack_into("<I", thin, p + 8, NEW_PLAT)
struct.pack_into("<I", thin, p + 12, NEW_MINOS)
# sdk 保持原值（0x1a0601 = 26.1）：sdk 只用于"用什么 SDK 构建"的记录，
# 不影响 dyld 的加载判定（dyld 只校验 platform 与 minos）。
new_plat, new_minos, new_sdk, _ = struct.unpack_from("<IIII", thin, p + 8)
log("  补丁后: platform=%d(%s) minos=0x%x(%s) sdk=0x%x(%s) [sdk 未动]" % (
    new_plat, "iOS" if new_plat == 2 else "?", new_minos, ver(new_minos), new_sdk, ver(new_sdk)))
assert (new_plat, new_minos, new_sdk) == (2, 0x120000, old_sdk)

# ---------------------------------------------------------------- 补丁 B
log()
log("== 补丁 B: LC_LOAD_DYLIB MobileDevice -> 我们的桩 ==")
NEWPATH = STUB_PATH
dylibs = [(p, cmd, sz) for p, cmd, sz in lcs if cmd == LC_LOAD_DYLIB]
log("  LC_LOAD_DYLIB 共 %d 条（顺序 = 后续 import 表里的 lib_ordinal 1/2/3，不能打乱）" % len(dylibs))
patched_b = None
for p, cmd, sz in dylibs:
    noff, = struct.unpack_from("<I", thin, p + 8)
    end = thin.index(b"\0", p + noff)
    s = thin[p + noff:end].decode()
    if "MobileDevice" in s and "MobileDevice.framework" in s:
        oldlen = end - (p + noff)
        log("  命中 @0x%04x cmdsize=%d 旧路径(%d 字节): %s" % (p, sz, oldlen, s))
        assert len(NEWPATH) + 1 <= oldlen, "新路径比旧路径长，不能在 cmdsize 内原地改写"
        # lc_str.offset 不变、cmdsize 不变，只在同一段空间里覆写并补 \0
        region = p + noff
        thin[region:region + oldlen] = NEWPATH + b"\0" * (oldlen - len(NEWPATH))
        # 校验：cmdsize 边界没被破坏，且新串可正常读出
        noff2, = struct.unpack_from("<I", thin, p + 8)
        end2 = thin.index(b"\0", p + noff2)
        s2 = thin[p + noff2:end2].decode()
        # 越界检查：字符串必须完整落在该 load command 的 cmdsize 之内
        assert p + noff2 + len(NEWPATH) < p + sz, "写穿了 cmdsize 边界！"
        # 下一个 load command 的 cmd 字段必须还是合法的
        nxt = p + sz
        if nxt < 32 + sum(s for _, _, s in lcs):
            ncmd, = struct.unpack_from("<I", thin, nxt)
            assert ncmd in LC_NAMES or (ncmd & ~LC_REQ_DYLD) in LC_NAMES, \
                "下一个 LC 的 cmd 被破坏: 0x%x" % ncmd
        log("  补丁后: offset=%d(未变) cmdsize=%d(未变) 新路径(%d 字节): %s" % (
            noff2, sz, len(NEWPATH), s2))
        log("  尾部填充: %d 个 \\0" % (oldlen - len(NEWPATH)))
        patched_b = (p, s, s2)
        break
assert patched_b, "没找到 MobileDevice 的 LC_LOAD_DYLIB"

# ---------------------------------------------------------------- 补丁 C
log()
log("== 补丁 C: macOS 的 `.../Versions/<X>/...` 依赖路径 -> iOS 扁平形态 ==")
#
# 为什么必须改（v0.3.455 加，GP-20 发现）：
#   dyld 解析依赖时，install name 是**按字符串精确匹配**共享缓存里的镜像名。
#   iOS 上**没有 `Versions/` 目录**，系统框架的 install name 是扁平形态：
#       /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
#   而 macOS 侧记录的是：
#       /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
#   ⇒ 在 iOS 上会直接 `Library not loaded: .../Versions/A/CoreFoundation` 失败。
#   ★ 这一条与「platform/minos 不匹配」是**两个独立**的加载期拦路虎，
#     只改 LC_BUILD_VERSION 不够。
#   扁平形态**一定更短**（少掉 `/Versions/<X>`）⇒ 原地覆写 + \0 填充，`cmdsize` 不变。

def flatten_versions(path: bytes) -> bytes:
    """`/a/Versions/A/b` -> `/a/b`（逐个剥掉每一段 `/Versions/<X>`）。"""
    marker = b"/Versions/"
    index = path.find(marker)
    while index != -1:
        slash = path.find(b"/", index + len(marker))
        if slash == -1:
            break
        path = path[:index] + path[slash:]
        index = path.find(marker)
    return path

# 所有「带 lc_str 名字、且名字是路径」的 load command：name.offset 都在 +8。
PATH_CMDS = (
    LC_LOAD_DYLIB,   # 0x0C
    0x18,            # LC_LOAD_WEAK_DYLIB
    0x1F,            # LC_REEXPORT_DYLIB
    0x20,            # LC_LAZY_LOAD_DYLIB
    0x23,            # LC_LOAD_UPWARD_DYLIB
    LC_ID_DYLIB,     # 0x0D
)
patched_c = []
for p, cmd, sz in lcs:
    if cmd not in PATH_CMDS:
        continue
    noff, = struct.unpack_from("<I", thin, p + 8)
    end = thin.index(b"\0", p + noff)
    raw = bytes(thin[p + noff:end])
    if b"/Versions/" not in raw:
        continue
    flat = flatten_versions(raw)
    oldlen = end - (p + noff)
    assert len(flat) + 1 <= oldlen, "扁平形态竟然更长？不成立的前提，停下"
    region = p + noff
    thin[region:region + oldlen] = flat + b"\0" * (oldlen - len(flat))
    # 校验：cmdsize 边界没被破坏、新串可读、下一个 LC 的 cmd 仍合法
    noff2, = struct.unpack_from("<I", thin, p + 8)
    end2 = thin.index(b"\0", p + noff2)
    assert thin[p + noff2:end2] == flat, "补丁 C 覆写校验失败"
    assert p + noff2 + len(flat) < p + sz, "补丁 C 写穿了 cmdsize 边界"
    nxt = p + sz
    if nxt < 32 + sum(s for _, _, s in lcs):
        ncmd, = struct.unpack_from("<I", thin, nxt)
        assert ncmd in LC_NAMES or (ncmd & ~LC_REQ_DYLD) in LC_NAMES, \
            "补丁 C 之后下一个 LC 的 cmd 被破坏: 0x%x" % ncmd
    log("  %-22s @0x%04x cmdsize=%d（未变）" % (lcname(cmd), p, sz))
    log("      旧: %s" % raw.decode())
    log("      新: %s" % flat.decode())
    patched_c.append((cmd, raw.decode(), flat.decode()))
log("  共改 %d 条" % len(patched_c))
assert patched_c, "一条 `Versions/` 路径都没改到 —— 前提不成立，请复核（不该静默通过）"

# ---------------------------------------------------------------- 枚举 undefined symbols
log()
log("== SYMTAB undefined symbols ==")
sym = [(p, cmd, sz) for p, cmd, sz in lcs if cmd == LC_SYMTAB]
assert len(sym) == 1
p, cmd, sz = sym[0]
symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", thin, p + 8)
log("  symoff=%d nsyms=%d stroff=%d strsize=%d" % (symoff, nsyms, stroff, strsize))
undef_all = []
for i in range(nsyms):
    o = symoff + i * 16
    n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", thin, o)
    if (n_type & 0xE0) == 0 and (n_type & 0x0E) == 0x00 and n_value == 0:
        s = thin[stroff + n_strx:thin.index(b"\0", stroff + n_strx)].decode()
        undef_all.append(s)
undef_all = sorted(set(undef_all))
log("  undefined (N_UNDF, n_value==0) 共 %d 个" % len(undef_all))

# ---------------------------------------------------------------- chained fixups import 表
log()
log("== LC_DYLD_CHAINED_FIXUPS import 表（按 lib_ordinal 归类） ==")
cf = [(p, cmd, sz) for p, cmd, sz in lcs if cmd == LC_DYLD_CHAINED_FIXUPS]
assert len(cf) == 1, "没有 chained fixups"
p, cmd, sz = cf[0]
dataoff, datasize = struct.unpack_from("<II", thin, p + 8)
log("  dataoff=%d datasize=%d" % (dataoff, datasize))
fx = dataoff
fver, starts_off, imports_off, symbols_off, imports_count, imports_format, symbols_format = \
    struct.unpack_from("<IIIIIII", thin, fx)
log("  fixups_version=%d imports_count=%d imports_format=%d symbols_format=%d" %
    (fver, imports_count, imports_format, symbols_format))
assert imports_format == 1, "imports_format=%d 暂不支持" % imports_format
assert symbols_format == 0, "symbols_format=%d 暂不支持" % symbols_format

# lib_ordinal -> dylib 路径
ordmap = {}
for k, (pp, cc, ss) in enumerate(dylibs):
    noff, = struct.unpack_from("<I", thin, pp + 8)
    e = thin.index(b"\0", pp + noff)
    ordmap[k + 1] = thin[pp + noff:e].decode()

imports = {}
for i in range(imports_count):
    o = fx + imports_off + i * 4
    raw, = struct.unpack_from("<I", thin, o)
    lib_ord = raw & 0xFF
    weak = (raw >> 8) & 1
    name_off = raw >> 9
    no = fx + symbols_off + name_off
    name = thin[no:thin.index(b"\0", no)].decode()
    imports.setdefault(lib_ord, []).append((name, weak))

for ord_ in sorted(imports):
    if ord_ == 0:
        lbl = "<BIND_SPECIAL_DYLIB_SELF>"
    elif ord_ == 0xFE:
        lbl = "<BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE>"
    elif ord_ == 0xFF:
        lbl = "<BIND_SPECIAL_DYLIB_FLAT_LOOKUP>"
    else:
        lbl = ordmap.get(ord_, "<未知 ordinal>")
    log("  ordinal %-4s -> %-3d 个符号   %s" % (ord_, len(imports[ord_]), lbl))

# MobileDevice 的 ordinal（路径里含 MobileDevice）
md_ord = None
for ord_, path in ordmap.items():
    if "MobileDevice" in path:
        md_ord = ord_
assert md_ord, "找不到 MobileDevice 的 ordinal"
md_syms = sorted(set(n for n, w in imports[md_ord]))
log()
log("  MobileDevice 是 ordinal %d，导入 %d 个符号" % (md_ord, len(md_syms)))

# 交叉核对：MobileDevice 的符号必须都在 SYMTAB 的 undefined 里
missing = [s for s in md_syms if s not in undef_all]
log("  交叉核对: %d/%d 出现在 SYMTAB undefined 中" % (len(md_syms) - len(missing), len(md_syms)))
if missing:
    log("  !! SYMTAB 里找不到的: %s" % missing)

with open(os.path.join(OUTDIR, "mobiledevice-imports.txt"), "w", encoding="utf-8") as f:
    f.write("# AirTrafficHost(arm64e) 从 MobileDevice 导入的符号 —— 这就是 libMobileDeviceStub.dylib 要导出的清单\n")
    f.write("# 来源: LC_DYLD_CHAINED_FIXUPS import 表 (lib_ordinal=%d), 交叉核对 LC_SYMTAB undefined\n" % md_ord)
    f.write("# 共 %d 个\n" % len(md_syms))
    for s in md_syms:
        f.write(s + "\n")
log("  -> 写入 _tmp_fw/mobiledevice-imports.txt")

# 另外两个 dylib 的导入也记下来，方便判断 iOS 上是否都有
for ord_, path in ordmap.items():
    if ord_ == md_ord:
        continue
    names = sorted(set(n for n, w in imports.get(ord_, [])))
    log("  参考: ordinal %d (%s) 导入 %d 个: %s" %
        (ord_, os.path.basename(path), len(names), ", ".join(names[:12]) + (" ..." if len(names) > 12 else "")))

# ---------------------------------------------------------------- 落盘
dst = OUT_FILE
open(dst, "wb").write(bytes(thin))
log()
log("== 落盘 ==")
log("  %s  (%d 字节)" % (dst, len(thin)))
log("  前后大小一致: %s" % (len(thin) == size))

with open(os.path.join(OUTDIR, "PATCH-REPORT.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")

print()
print("OK")
