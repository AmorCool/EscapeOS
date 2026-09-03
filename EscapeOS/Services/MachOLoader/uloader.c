//
//  uloader.c
//  EscapeOS
//
//  用户态 Mach-O dylib 加载器（v0.3.108）
//  —— 移植自 Nyxian 的 ProcEnvironment/Surface/kxld（AGPL-3.0-or-later，emexlab）
//
//  为什么需要它：
//  dlopen() 会经过 dyld 的**库校验（library validation）**，ad-hoc 签名（无 CMS
//  blob）的 dylib 在 dyld 层必被拒（实测 "code signature invalid"）。
//  LC / Nyxian 加载访客代码不走 dyld：自己 mmap 段 + 自己做 rebase/bind + 自己跑
//  构造器。本文件即该机制的最小可用实现。
//
//  映射流程（对齐 kxld/mapper.c）：
//  1) PROT_NONE 预留整段地址空间
//  2) 按 segment->initprot 逐段 MAP_FIXED 映射（可写段 MAP_PRIVATE，只读/执行段 MAP_SHARED 文件映射）
//  3) vmsize > filesize 的部分用匿名内存补齐（BSS）
//  4) LC_DYLD_INFO(_ONLY) rebase 修正 slide
//  5) LC_DYLD_INFO(_ONLY) bind：外部符号用 dlsym(RTLD_DEFAULT) 解析
//  6) 执行 __mod_init_func 构造器
//  7) 符号查找走 LC_SYMTAB（nlist 表，比 export trie 简单可靠）
//
//  SPDX-License-Identifier: AGPL-3.0-or-later
//

#include "uloader.h"

// iOS 15+ 新格式：chained fixups（本模块 dylib 用的就是它，没有 LC_DYLD_INFO）
#define LC_DYLD_CHAINED_FIXUPS_       0x80000034
#define LC_DYLD_CHAINED_FIXUPS_PLAIN  0x34
#define DYLD_CHAINED_PTR_START_NONE   0xFFFF
#define DYLD_CHAINED_PTR_START_MULTI  0x8000

// 位布局（dyld_chained_fixups.h 规范 + 真实 dylib 353634 条全量仿真验证）：
//   bit63        = bind 标志（1=bind，0=rebase）
//   bits51-62    = next：到下一条的偏移，**单位是 4 字节**（不是 8！）
//   rebase:      target = bits0-42（36+7=43 位）；对 PTR_64_OFFSET 是相对镜像基址的偏移
//   bind:        ordinal = bits0-23（24 位），addend = bits24-31，reserved = bits32-50
#define CHAIN_BIND_MASK    (1ULL << 63)
#define CHAIN_TARGET_MASK  0x7FFFFFFFFFFULL      // 43 位（rebase）
#define CHAIN_ORDINAL_MASK 0xFFFFFFULL           // 24 位（bind 序号）
#define CHAIN_ADDEND_SHIFT 24
#define CHAIN_NEXT_SHIFT   51
#define CHAIN_NEXT_MASK    0xFFF
#define CHAIN_STRIDE       4                       // next 的单位字节数


#include <dlfcn.h>
#include <errno.h>
#include <libkern/OSByteOrder.h>
#include <stdio.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// dyld 重定位/绑定 opcode（dyld_info 标准值）
#define REBASE_OPCODE_MASK                  0xF0
#define REBASE_IMMEDIATE_MASK               0x0F
#define REBASE_OPCODE_DONE                  0x00
#define REBASE_OPCODE_SET_TYPE_IMM          0x10
#define REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB 0x20
#define REBASE_OPCODE_ADD_ADDR_ULEB         0x30
#define REBASE_OPCODE_ADD_ADDR_IMM_SCALED   0x40
#define REBASE_OPCODE_DO_REBASE_IMM_TIMES   0x50
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES  0x60
#define REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB 0x70
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 0x80

#define BIND_OPCODE_MASK                    0xF0
#define BIND_IMMEDIATE_MASK                 0x0F
#define BIND_OPCODE_DONE                    0x00
#define BIND_OPCODE_SET_DYLIB_ORDINAL_IMM   0x10
#define BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB  0x20
#define BIND_OPCODE_SET_DYLIB_SPECIAL_IMM   0x30
#define BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM 0x40
#define BIND_OPCODE_SET_TYPE_IMM            0x50
#define BIND_OPCODE_SET_ADDEND_SLEB         0x60
#define BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB 0x70
#define BIND_OPCODE_ADD_ADDR_ULEB           0x80
#define BIND_OPCODE_DO_BIND                 0x90
#define BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB   0xA0
#define BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED 0xB0
#define BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB 0xC0

#define BIND_TYPE_POINTER                   1
#define REBASE_TYPE_POINTER                 1

struct uloader_image {
    int fd;
    void *fileMap;         // 整个文件的只读映射（解析用）
    size_t fileSize;
    const uint8_t *header; // 实际 Mach-O 头（可能是 fat 中的切片）
    size_t sliceOffset;

    void *base;            // 加载后的镜像基址
    size_t len;
    intptr_t slide;

    // 段信息（用于 bind 的 segment/offset 换算）
    uint64_t segVmAddrs[16];
    uint64_t segVmSizes[16];
    uint64_t segFileOffs[16];
    uint32_t segCount;

    // 代码签名 blob（供 F_ADDFILESIGS_RETURN 登记）
    uint32_t codeSigOff, codeSigSize;
    // chained fixups（新格式）
    uint32_t chainedOff, chainedSize;
    // dyld info（旧格式，备用）
    const uint8_t *dyldInfo;
    uint32_t rebaseOff, rebaseSize, bindOff, bindSize, weakBindOff, weakBindSize,
             lazyBindOff, lazyBindSize, exportOff, exportSize;

    // 符号表
    const struct nlist_64 *symtab;
    const char *strtab;
    uint32_t nsyms;

    char lastError[256];
};

// ---- ULEB128 / SLEB128 解码 ----

static uint64_t read_uleb128(const uint8_t **pp, const uint8_t *end) {
    uint64_t result = 0;
    int bit = 0;
    const uint8_t *p = *pp;
    do {
        if (p >= end) break;
        uint64_t slice = *p & 0x7f;
        if (bit >= 64) { p++; break; }
        result |= (slice << bit);
        bit += 7;
    } while (*p++ & 0x80);
    *pp = p;
    return result;
}

static int64_t read_sleb128(const uint8_t **pp, const uint8_t *end) {
    int64_t result = 0;
    int bit = 0;
    const uint8_t *p = *pp;
    uint8_t byte = 0;
    do {
        if (p >= end) break;
        byte = *p++;
        result |= ((int64_t)(byte & 0x7f) << bit);
        bit += 7;
    } while (byte & 0x80);
    // 符号扩展
    if (byte & 0x40) result |= (~0ULL << bit);
    *pp = p;
    return result;
}

static void set_error(struct uloader_image *img, const char *msg) {
    strncpy(img->lastError, msg, sizeof(img->lastError) - 1);
    img->lastError[sizeof(img->lastError) - 1] = 0;
}

// ---- 段地址换算 ----

static int addr_to_offset(struct uloader_image *img, uint64_t addr, uint32_t *outFileOff) {
    // addr 是已 slide 的运行时地址（rebase/bind 流中的 segOffset 是未 slide 的 vmaddr）
    for (uint32_t i = 0; i < img->segCount; i++) {
        uint64_t vmStart = img->segVmAddrs[i];
        uint64_t vmEnd = vmStart + img->segVmSizes[i];
        if (addr >= vmStart && addr < vmEnd) {
            *outFileOff = (uint32_t)(img->segFileOffs[i] + (addr - vmStart));
            return 0;
        }
    }
    return -1;
}

static void *uloader_ptr(struct uloader_image *img, uint32_t segIndex, uint64_t segOffset) {
    if (segIndex >= img->segCount) return NULL;
    uint64_t vmaddr = img->segVmAddrs[segIndex] + segOffset;
    return (void *)(uintptr_t)(vmaddr + img->slide);
}

// ---- 映射（移植自 kxld/mapper.c）----

static bool uloader_map_segments(struct uloader_image *img) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)img->header;
    const uint8_t *ptr = img->header + sizeof(struct mach_header_64);

    uint64_t vmStart = ~0ULL, vmEnd = 0;

    // 1) 计算地址空间范围 + 收集段信息
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)ptr;
            if (sc->vmsize > 0) {
                if (sc->vmaddr < vmStart) vmStart = sc->vmaddr;
                if (sc->vmaddr + sc->vmsize > vmEnd) vmEnd = sc->vmaddr + sc->vmsize;
                if (img->segCount < 16) {
                    uint32_t idx = img->segCount++;
                    img->segVmAddrs[idx] = sc->vmaddr;
                    img->segVmSizes[idx] = sc->vmsize;
                    img->segFileOffs[idx] = sc->fileoff;
                }
            }
        }
        ptr += lc->cmdsize;
    }

    if (vmEnd <= vmStart) { set_error(img, "（映射）无有效段"); return false; }

    // 2) PROT_NONE 预留
    img->len = (size_t)(vmEnd - vmStart);
    img->base = mmap(NULL, img->len, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (img->base == MAP_FAILED) { set_error(img, "（映射）预留地址空间失败"); return false; }
    img->slide = (intptr_t)img->base - (intptr_t)vmStart;

    // 3) 逐段 MAP_FIXED
    ptr = img->header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)ptr;
            if (sc->vmsize > 0) {
                void *addr = (void *)(uintptr_t)(sc->vmaddr + img->slide);
                off_t fileOff = (off_t)(img->sliceOffset + sc->fileoff);
                int prot = 0;
                if (sc->initprot & VM_PROT_READ)    prot |= PROT_READ;
                if (sc->initprot & VM_PROT_WRITE)   prot |= PROT_WRITE;
                if (sc->initprot & VM_PROT_EXECUTE) prot |= PROT_EXEC;
                int flags = (sc->initprot & VM_PROT_WRITE)
                            ? (MAP_PRIVATE | MAP_FIXED)
                            : (MAP_SHARED  | MAP_FIXED);

                if (sc->filesize > 0) {
                    void *r = mmap(addr, sc->filesize, prot, flags, img->fd, fileOff);
                    if (r == MAP_FAILED) {
                        set_error(img, "（映射）段映射失败");
                        return false;
                    }
                }
                // BSS：vmsize 超出 filesize 的整页尾部
                if (sc->vmsize > sc->filesize) {
                    size_t pageSize = (size_t)getpagesize();
                    uintptr_t fileEnd = (uintptr_t)addr + sc->filesize;
                    uintptr_t bssStart = (fileEnd + pageSize - 1) & ~(uintptr_t)(pageSize - 1);
                    uintptr_t bssEnd = ((uintptr_t)addr + sc->vmsize + pageSize - 1) & ~(uintptr_t)(pageSize - 1);
                    if (bssEnd > bssStart) {
                        void *r = mmap((void *)bssStart, bssEnd - bssStart, prot,
                                       MAP_PRIVATE | MAP_FIXED | MAP_ANON, -1, 0);
                        if (r == MAP_FAILED) {
                            set_error(img, "（映射）BSS 映射失败");
                            return false;
                        }
                    }
                }
            }
        }
        ptr += lc->cmdsize;
    }
    return true;
}

// ---- rebase ----

static bool uloader_rebase(struct uloader_image *img) {
    if (img->rebaseSize == 0) return true;
    const uint8_t *p = img->dyldInfo + img->rebaseOff;
    const uint8_t *end = p + img->rebaseSize;

    uint8_t type = 0;
    uint32_t segIndex = 0;
    uint64_t segOffset = 0;

    while (p < end) {
        uint8_t opcode = *p++;
        uint8_t imm = opcode & REBASE_IMMEDIATE_MASK;
        opcode &= REBASE_OPCODE_MASK;

        switch (opcode) {
            case REBASE_OPCODE_DONE:
                return true;
            case REBASE_OPCODE_SET_TYPE_IMM:
                type = imm;
                break;
            case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segIndex = (uint32_t)imm;
                segOffset = read_uleb128(&p, end);
                break;
            case REBASE_OPCODE_ADD_ADDR_ULEB:
                segOffset += read_uleb128(&p, end);
                break;
            case REBASE_OPCODE_ADD_ADDR_IMM_SCALED:
                segOffset += imm * sizeof(uintptr_t);
                break;
            case REBASE_OPCODE_DO_REBASE_IMM_TIMES: {
                for (uint8_t i = 0; i < imm; i++) {
                    void *loc = uloader_ptr(img, segIndex, segOffset);
                    if (!loc) { set_error(img, "（rebase）地址越界"); return false; }
                    if (type == REBASE_TYPE_POINTER) {
                        uintptr_t val = *(uintptr_t *)loc;
                        *(uintptr_t *)loc = val + (uintptr_t)img->slide;
                    }
                    segOffset += sizeof(uintptr_t);
                }
                break;
            }
            case REBASE_OPCODE_DO_REBASE_ULEB_TIMES: {
                uint64_t count = read_uleb128(&p, end);
                for (uint64_t i = 0; i < count; i++) {
                    void *loc = uloader_ptr(img, segIndex, segOffset);
                    if (!loc) { set_error(img, "（rebase）地址越界"); return false; }
                    if (type == REBASE_TYPE_POINTER) {
                        uintptr_t val = *(uintptr_t *)loc;
                        *(uintptr_t *)loc = val + (uintptr_t)img->slide;
                    }
                    segOffset += sizeof(uintptr_t);
                }
                break;
            }
            case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: {
                void *loc = uloader_ptr(img, segIndex, segOffset);
                if (!loc) { set_error(img, "（rebase）地址越界"); return false; }
                if (type == REBASE_TYPE_POINTER) {
                    uintptr_t val = *(uintptr_t *)loc;
                    *(uintptr_t *)loc = val + (uintptr_t)img->slide;
                }
                segOffset += sizeof(uintptr_t) + read_uleb128(&p, end);
                break;
            }
            case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t count = read_uleb128(&p, end);
                uint64_t skip = read_uleb128(&p, end);
                for (uint64_t i = 0; i < count; i++) {
                    void *loc = uloader_ptr(img, segIndex, segOffset);
                    if (!loc) { set_error(img, "（rebase）地址越界"); return false; }
                    if (type == REBASE_TYPE_POINTER) {
                        uintptr_t val = *(uintptr_t *)loc;
                        *(uintptr_t *)loc = val + (uintptr_t)img->slide;
                    }
                    segOffset += sizeof(uintptr_t) + skip;
                }
                break;
            }
            default:
                set_error(img, "（rebase）未知 opcode");
                return false;
        }
    }
    return true;
}

// ---- bind（外部符号用 dlsym 解析到本进程）----

static bool uloader_bind(struct uloader_image *img) {
    if (img->bindSize == 0) return true;
    const uint8_t *p = img->dyldInfo + img->bindOff;
    const uint8_t *end = p + img->bindSize;

    int ordinal = 0;
    uint8_t type = BIND_TYPE_POINTER;
    int64_t addend = 0;
    uint32_t segIndex = 0;
    uint64_t segOffset = 0;
    const char *symName = NULL;

    while (p < end) {
        uint8_t opcode = *p++;
        uint8_t imm = opcode & BIND_IMMEDIATE_MASK;
        opcode &= BIND_OPCODE_MASK;

        switch (opcode) {
            case BIND_OPCODE_DONE:
                return true;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
                ordinal = (int)imm;
                break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                ordinal = (int)read_uleb128(&p, end);
                break;
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                ordinal = (int)(int8_t)imm; // 负数表示特殊（flat/weak 等），统一按普通解析处理
                break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
                symName = (const char *)p;
                while (p < end && *p != 0) p++;
                p++; // 跳过结尾 0
                break;
            }
            case BIND_OPCODE_SET_TYPE_IMM:
                type = imm;
                break;
            case BIND_OPCODE_SET_ADDEND_SLEB:
                addend = read_sleb128(&p, end);
                break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segIndex = (uint32_t)imm;
                segOffset = read_uleb128(&p, end);
                break;
            case BIND_OPCODE_ADD_ADDR_ULEB:
                segOffset += read_uleb128(&p, end);
                break;
            case BIND_OPCODE_DO_BIND: {
                void *loc = uloader_ptr(img, segIndex, segOffset);
                if (!loc || !symName) { set_error(img, "（bind）位置或符号为空"); return false; }
                // 去掉 Mach-O 符号前导下划线后在本进程查找
                const char *lookup = (*symName == '_') ? (symName + 1) : symName;
                void *sym = dlsym(RTLD_DEFAULT, lookup);
                if (!sym) {
                    snprintf(img->lastError, sizeof(img->lastError),
                             "（bind）符号未找到: %s", lookup);
                    return false;
                }
                if (type == BIND_TYPE_POINTER) {
                    *(uintptr_t *)loc = (uintptr_t)sym + (uintptr_t)addend;
                }
                segOffset += sizeof(uintptr_t);
                break;
            }
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: {
                void *loc = uloader_ptr(img, segIndex, segOffset);
                if (!loc || !symName) { set_error(img, "（bind）位置或符号为空"); return false; }
                const char *lookup = (*symName == '_') ? (symName + 1) : symName;
                void *sym = dlsym(RTLD_DEFAULT, lookup);
                if (!sym) {
                    snprintf(img->lastError, sizeof(img->lastError),
                             "（bind）符号未找到: %s", lookup);
                    return false;
                }
                if (type == BIND_TYPE_POINTER) {
                    *(uintptr_t *)loc = (uintptr_t)sym + (uintptr_t)addend;
                }
                segOffset += sizeof(uintptr_t) + read_uleb128(&p, end);
                break;
            }
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: {
                void *loc = uloader_ptr(img, segIndex, segOffset);
                if (!loc || !symName) { set_error(img, "（bind）位置或符号为空"); return false; }
                const char *lookup = (*symName == '_') ? (symName + 1) : symName;
                void *sym = dlsym(RTLD_DEFAULT, lookup);
                if (!sym) {
                    snprintf(img->lastError, sizeof(img->lastError),
                             "（bind）符号未找到: %s", lookup);
                    return false;
                }
                if (type == BIND_TYPE_POINTER) {
                    *(uintptr_t *)loc = (uintptr_t)sym + (uintptr_t)addend;
                }
                segOffset += sizeof(uintptr_t) + imm * sizeof(uintptr_t);
                break;
            }
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t count = read_uleb128(&p, end);
                uint64_t skip = read_uleb128(&p, end);
                for (uint64_t i = 0; i < count; i++) {
                    void *loc = uloader_ptr(img, segIndex, segOffset);
                    if (!loc || !symName) { set_error(img, "（bind）位置或符号为空"); return false; }
                    const char *lookup = (*symName == '_') ? (symName + 1) : symName;
                    void *sym = dlsym(RTLD_DEFAULT, lookup);
                    if (!sym) {
                        snprintf(img->lastError, sizeof(img->lastError),
                                 "（bind）符号未找到: %s", lookup);
                        return false;
                    }
                    if (type == BIND_TYPE_POINTER) {
                        *(uintptr_t *)loc = (uintptr_t)sym + (uintptr_t)addend;
                    }
                    segOffset += sizeof(uintptr_t) + skip;
                }
                break;
            }
            default:
                set_error(img, "（bind）未知 opcode");
                return false;
        }
    }
    return true;
}


// ---- chained fixups（iOS 15+ 新格式；本模块 dylib 实际使用）----

static bool uloader_chained_fixups(struct uloader_image *img) {
    const uint8_t *cf = img->header + img->chainedOff;
    uint32_t startsOff     = *(const uint32_t *)(cf + 4);
    uint32_t importsOff    = *(const uint32_t *)(cf + 8);
    uint32_t symbolsOff    = *(const uint32_t *)(cf + 12);
    uint32_t importsCount  = *(const uint32_t *)(cf + 16);
    uint32_t segCount      = *(const uint32_t *)cf;   // starts_in_image.seg_count

    const uint8_t *starts = cf + startsOff;

    for (uint32_t si = 0; si < segCount && si < 16; si++) {
        uint32_t sio = *(const uint32_t *)(starts + 4 + si * 4);
        if (sio == 0) continue;

        const uint8_t *segInfo = starts + sio;
        uint32_t pageSize      = *(const uint16_t *)(segInfo + 4);
        uint64_t segmentOffset = *(const uint64_t *)(segInfo + 8);
        uint16_t pageCount     = *(const uint16_t *)(segInfo + 18);
        const uint16_t *pageStarts = (const uint16_t *)(segInfo + 22);
        if (pageSize == 0) pageSize = 0x4000;

        // 用段的文件偏移匹配到我们记录的段，从而拿到 vmaddr 基址
        int segIdx = -1;
        for (uint32_t i = 0; i < img->segCount; i++) {
            if (img->segFileOffs[i] == segmentOffset) { segIdx = (int)i; break; }
        }
        if (segIdx < 0) continue;

        for (uint32_t pg = 0; pg < pageCount; pg++) {
            uint16_t ps = pageStarts[pg];
            if (ps == DYLD_CHAINED_PTR_START_NONE) continue;
            if (ps & DYLD_CHAINED_PTR_START_MULTI) continue;   // multi 起点暂不支持（本 dylib 未使用）

            uint64_t offsetInPage = ps;
            while (true) {
                uint64_t loc = img->segVmAddrs[segIdx] + (uint64_t)img->slide
                             + (uint64_t)pg * pageSize + offsetInPage;
                uint64_t *slot = (uint64_t *)(uintptr_t)loc;
                uint64_t val   = *slot;

                bool isBind = (val & CHAIN_BIND_MASK) != 0;
                uint64_t target = val & CHAIN_TARGET_MASK;
                uint32_t next   = (uint32_t)((val >> CHAIN_NEXT_SHIFT) & CHAIN_NEXT_MASK);

                if (isBind) {
                    // bind：序号在低 24 位，addend 在 bits24-31（v0.3.117 修正：
                    // 旧实现用 51 位 target 当序号，addend≠0 时解析错）
                    uint64_t ordinal = val & CHAIN_ORDINAL_MASK;
                    uint64_t addend  = (val >> CHAIN_ADDEND_SHIFT) & 0xFF;
                    if (ordinal >= importsCount) { set_error(img, "（chain）imports 序号越界"); return false; }
                    uint32_t w = *(const uint32_t *)(cf + importsOff + (uint32_t)ordinal * 4);
                    uint32_t nameOff = w >> 9;   // lib_ordinal:8 + weak:1
                    const char *symName = (const char *)(cf + symbolsOff + nameOff);
                    const char *lookup = (symName[0] == '_') ? (symName + 1) : symName;
                    // 解析顺序：① 本镜像 symtab（x_cgo_inittls 等 Go 运行时符号
                    //   虽在 imports 里但定义在本 dylib 内）→ ② dlsym 全局 →
                    //   ③ 兜底 dlopen libresolv（_res_9_* 所在库，宿主默认不加载）
                    void *sym = uloader_symbol((void *)img, symName);
                    if (!sym) sym = dlsym(RTLD_DEFAULT, lookup);
                    if (!sym) {
                        static bool libresolvTried = false;
                        if (!libresolvTried) {
                            libresolvTried = true;
                            dlopen("libresolv.9.dylib", RTLD_NOW | RTLD_GLOBAL);
                            sym = dlsym(RTLD_DEFAULT, lookup);
                        }
                    }
                    if (!sym) {
                        snprintf(img->lastError, sizeof(img->lastError),
                                 "（chain）符号未找到: %s", lookup);
                        return false;
                    }
                    *slot = (uint64_t)(uintptr_t)sym + addend;
                } else {
                    // rebase：target 43 位；PTR_64_OFFSET 格式下是相对镜像基址的偏移
                    // （本 dylib __TEXT vmaddr=0 已实测，imageBase=0 → +slide 即可）
                    *slot = target + (uint64_t)img->slide;
                }

                if (next == 0) break;
                offsetInPage += (uint64_t)next * CHAIN_STRIDE;   // ★ 规范：next 单位是 4 字节
                if (offsetInPage >= pageSize) break;   // 链走出本页即结束
            }
        }
    }
    return true;
}

// ---- 构造器（__mod_init_func）----

static void uloader_run_initializers(struct uloader_image *img) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)img->header;
    const uint8_t *ptr = img->header + sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)ptr;
            const uint8_t *sp = (const uint8_t *)sc + sizeof(struct segment_command_64);
            for (uint32_t j = 0; j < sc->nsects; j++) {
                const struct section_64 *sect = (const struct section_64 *)sp;
                if ((sect->flags & SECTION_TYPE) == S_MOD_INIT_FUNC_POINTERS) {
                    uintptr_t *funcs = (uintptr_t *)(uintptr_t)(sect->addr + img->slide);
                    uint64_t count = sect->size / sizeof(uintptr_t);
                    for (uint64_t k = 0; k < count; k++) {
                        if (funcs[k] == 0) continue;
                        void (*init)(void) = (void (*)(void))funcs[k];
                        init();
                    }
                }
                sp += sizeof(struct section_64);
            }
        }
        ptr += lc->cmdsize;
    }
}


// ---- 通用入口符号发现：扫描 LC_SYMTAB 中"以后缀结尾"的已定义外部符号 ----
// 用途：引擎不该知道任何模块的符号名（如某模块导出 XxxMain）。
// 调用方拿到候选名后用 dlsym 逐个尝试即可，实现零模块耦合。
int uloader_symbols_with_suffix(const char *path, const char *suffix,
                                char *outBuf, int outBufSize) {
    if (!path || !suffix || !outBuf || outBufSize <= 0) return 0;
    outBuf[0] = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    off_t fsize = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    void *map = mmap(NULL, (size_t)fsize, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) { close(fd); return 0; }

    int found = 0;
    size_t used = 0;
    const uint8_t *hdr = (const uint8_t *)map;
    uint32_t magic = *(const uint32_t *)hdr;
    const uint8_t *base = hdr;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        const struct fat_header *fh = (const struct fat_header *)hdr;
        uint32_t nfat = (magic == FAT_MAGIC) ? fh->nfat_arch : OSSwapInt32(fh->nfat_arch);
        const struct fat_arch *fa = (const struct fat_arch *)(hdr + sizeof(struct fat_header));
        for (uint32_t i = 0; i < nfat; i++) {
            cpu_type_t ct = (magic == FAT_MAGIC) ? fa[i].cputype : OSSwapInt32(fa[i].cputype);
            uint32_t off = (magic == FAT_MAGIC) ? fa[i].offset : OSSwapInt32(fa[i].offset);
            if (ct == CPU_TYPE_ARM64) { base = hdr + off; break; }
        }
        void *newmap = mmap(NULL, (size_t)fsize, PROT_READ, MAP_PRIVATE, fd, 0);
        if (newmap != MAP_FAILED) { munmap(newmap, (size_t)fsize); }
    }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)base;
    if (mh->magic == MH_MAGIC_64 && mh->cputype == CPU_TYPE_ARM64) {
        const uint8_t *ptr = base + sizeof(struct mach_header_64);
        uint32_t symoff = 0, nsyms = 0, stroff = 0;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)ptr;
            if (lc->cmd == LC_SYMTAB) {
                const struct symtab_command *st = (const struct symtab_command *)ptr;
                symoff = st->symoff; nsyms = st->nsyms; stroff = st->stroff;
            }
            ptr += lc->cmdsize;
        }
        if (nsyms > 0) {
            const struct nlist_64 *syms = (const struct nlist_64 *)(base + symoff);
            const char *strs = (const char *)(base + stroff);
            size_t slen = strlen(suffix);
            for (uint32_t i = 0; i < nsyms && found < 8; i++) {
                if ((syms[i].n_type & N_TYPE) != N_SECT) continue;   // 只要本镜像定义的
                if (syms[i].n_value == 0) continue;
                const char *name = strs + syms[i].n_un.n_strx;
                size_t nlen = strlen(name);
                if (nlen < slen) continue;
                if (strncmp(name + (nlen - slen), suffix, slen) != 0) continue;
                // 追加到输出（换行分隔）
                size_t need = nlen + 1;
                if (used + need + 1 >= (size_t)outBufSize) break;
                if (used > 0) { outBuf[used++] = '\n'; }
                memcpy(outBuf + used, name, nlen);
                used += nlen;
                outBuf[used] = 0;
                found++;
            }
        }
    }
    munmap(map, (size_t)fsize);
    close(fd);
    return found;
}

// ---- 公开接口 ----

void *uloader_load(const char *path, char *errBuf, size_t errBufSize) {
    struct uloader_image *img = calloc(1, sizeof(struct uloader_image));
    if (!img) return NULL;

    img->fd = open(path, O_RDONLY);
    if (img->fd < 0) { free(img); if (errBuf) snprintf(errBuf, errBufSize, "打开文件失败"); return NULL; }

    off_t fileSize = lseek(img->fd, 0, SEEK_END);
    lseek(img->fd, 0, SEEK_SET);
    img->fileSize = (size_t)fileSize;
    img->fileMap = mmap(NULL, img->fileSize, PROT_READ, MAP_PRIVATE, img->fd, 0);
    if (img->fileMap == MAP_FAILED) {
        close(img->fd); free(img);
        if (errBuf) snprintf(errBuf, errBufSize, "映射文件失败");
        return NULL;
    }

    const uint8_t *base = (const uint8_t *)img->fileMap;
    uint32_t magic = *(const uint32_t *)base;

    // fat 二进制：挑 arm64 切片
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        const struct fat_header *fh = (const struct fat_header *)base;
        uint32_t nfat = magic == FAT_MAGIC ? fh->nfat_arch : OSSwapInt32(fh->nfat_arch);
        const struct fat_arch *fa = (const struct fat_arch *)(base + sizeof(struct fat_header));
        bool found = false;
        for (uint32_t i = 0; i < nfat; i++) {
            cpu_type_t ct = magic == FAT_MAGIC ? fa[i].cputype : OSSwapInt32(fa[i].cputype);
            uint32_t off = magic == FAT_MAGIC ? fa[i].offset : OSSwapInt32(fa[i].offset);
            if (ct == CPU_TYPE_ARM64) {
                img->sliceOffset = off;
                found = true;
                break;
            }
        }
        if (!found) {
            munmap(img->fileMap, img->fileSize); close(img->fd); free(img);
            if (errBuf) snprintf(errBuf, errBufSize, "fat 中无 arm64 切片");
            return NULL;
        }
        img->header = base + img->sliceOffset;
    } else {
        img->header = base;
        img->sliceOffset = 0;
    }

    const struct mach_header_64 *mh = (const struct mach_header_64 *)img->header;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) {
        munmap(img->fileMap, img->fileSize); close(img->fd); free(img);
        if (errBuf) snprintf(errBuf, errBufSize, "非 arm64 Mach-O");
        return NULL;
    }

    // 解析加载命令
    const uint8_t *ptr = img->header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
            const struct dyld_info_command *dic = (const struct dyld_info_command *)ptr;
            img->dyldInfo = img->header;
            img->rebaseOff = dic->rebase_off;    img->rebaseSize = dic->rebase_size;
            img->bindOff = dic->bind_off;        img->bindSize = dic->bind_size;
            img->weakBindOff = dic->weak_bind_off; img->weakBindSize = dic->weak_bind_size;
            img->lazyBindOff = dic->lazy_bind_off; img->lazyBindSize = dic->lazy_bind_size;
            img->exportOff = dic->export_off;    img->exportSize = dic->export_size;
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS_ || lc->cmd == LC_DYLD_CHAINED_FIXUPS_PLAIN) {
            const struct linkedit_data_command *ldc = (const struct linkedit_data_command *)ptr;
            img->chainedOff = ldc->dataoff;
            img->chainedSize = ldc->datasize;
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            const struct linkedit_data_command *cs = (const struct linkedit_data_command *)ptr;
            img->codeSigOff = cs->dataoff;
            img->codeSigSize = cs->datasize;
        } else if (lc->cmd == LC_SYMTAB) {
            const struct symtab_command *st = (const struct symtab_command *)ptr;
            img->symtab = (const struct nlist_64 *)(img->header + st->symoff);
            img->strtab = (const char *)(img->header + st->stroff);
            img->nsyms = st->nsyms;
        }
        ptr += lc->cmdsize;
    }

    if (!img->dyldInfo && img->chainedOff == 0) {
        munmap(img->fileMap, img->fileSize); close(img->fd); free(img);
        if (errBuf) snprintf(errBuf, errBufSize, "既无 LC_DYLD_INFO 也无 LC_DYLD_CHAINED_FIXUPS（无法重定位）");
        return NULL;
    }

    // ★ 映射前必须向内核登记签名（移植自 Nyxian kxld/validation.c）：
    //   iOS 不允许以 PROT_EXEC 映射未登记签名的文件——这正是 dlopen 与裸 mmap
    //   双双失败的根因。F_ADDFILESIGS_RETURN 把文件的 CMS blob 交给内核登记，
    //   F_CHECK_LV 做库校验；之后 mmap(PROT_EXEC) 才会被允许。
    {
        fsignatures_t siginfo = {
            .fs_file_start = img->sliceOffset,
            .fs_blob_start = (void *)(uintptr_t)img->codeSigOff,
            .fs_blob_size  = img->codeSigSize,
        };
        fchecklv_t checkInfo = { .lv_file_start = img->sliceOffset, 0 };  /* 其余置零 */

        if (fcntl(img->fd, F_ADDFILESIGS_RETURN, &siginfo) == -1) {
            snprintf(img->lastError, sizeof(img->lastError),
                     "（签名登记）F_ADDFILESIGS_RETURN 失败 errno=%d blob=0x%x/%u%s",
                     errno, img->codeSigOff, img->codeSigSize,
                     errno == 1 ? "（EPERM：内核/AMFI 拒绝该 blob——vnode 或已被缓存判无效，请用 zsign 重签后的全新文件）" : "");
            goto fail;
        }
        if (fcntl(img->fd, F_CHECK_LV, &checkInfo) == -1) {
            snprintf(img->lastError, sizeof(img->lastError),
                     "（签名登记）F_CHECK_LV 失败 errno=%d", errno);
            goto fail;
        }
    }

    if (!uloader_map_segments(img)) goto fail;
    if (img->chainedOff != 0) {
        if (!uloader_chained_fixups(img)) goto fail;
    } else {
        if (!uloader_rebase(img)) goto fail;
        if (!uloader_bind(img)) goto fail;
    }
    uloader_run_initializers(img);

    return img;

fail:
    if (errBuf) snprintf(errBuf, errBufSize, "%s", img->lastError);
    if (img->base) munmap(img->base, img->len);
    munmap(img->fileMap, img->fileSize);
    close(img->fd);
    free(img);
    return NULL;
}

void *uloader_symbol(void *handle, const char *name) {
    struct uloader_image *img = (struct uloader_image *)handle;
    if (!img || !img->symtab || !img->strtab) return NULL;

    // 兼容带/不带前导下划线的调用
    const char *want = name;
    const char *wantUs = (name[0] == '_') ? name : NULL;

    for (uint32_t i = 0; i < img->nsyms; i++) {
        const struct nlist_64 *nl = &img->symtab[i];
        if ((nl->n_type & N_TYPE) != N_SECT) continue;   // 只要本镜像定义的符号
        if (nl->n_value == 0) continue;
        const char *sym = img->strtab + nl->n_un.n_strx;
        bool match = false;
        if (wantUs && strcmp(sym, wantUs) == 0) match = true;
        if (!match) {
            if (want[0] == '_') {
                match = (strcmp(sym, want) == 0);
            } else if (sym[0] == '_') {
                match = (strcmp(sym + 1, want) == 0);
            }
        }
        if (match) {
            return (void *)(uintptr_t)(nl->n_value + img->slide);
        }
    }
    return NULL;
}

void uloader_unload(void *handle) {
    struct uloader_image *img = (struct uloader_image *)handle;
    if (!img) return;
    if (img->base) munmap(img->base, img->len);
    if (img->fileMap) munmap(img->fileMap, img->fileSize);
    if (img->fd >= 0) close(img->fd);
    free(img);
}
