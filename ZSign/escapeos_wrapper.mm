// EscapeOS 桥接：zsign ad-hoc 签名（对齐 LC adhocSignMachOAtPath 的引擎路径）。
// 输入：dylib 路径 + bundleId（可选 entitlements XML）。原文件就地重签
// —— 调用方必须先复制到全新路径（内核按 vnode 缓存校验判决，见 MachoReSign.swift）。
#import <Foundation/Foundation.h>
#include <string.h>
#include "openssl.h"
#include "macho.h"

extern "C" int zsign_adhoc_file(const char* path,
                                const char* bundleId,
                                const char* entXml,
                                int entLen) {
    if (!path || !bundleId) return -2;
    ZLog::logs.clear();
    ZSignAsset asset;
    if (!asset.InitAdhoc(entXml, entLen)) return -1;   // ad-hoc 模式（无证书）
    ZMachO* macho = new ZMachO();
    if (!macho->Init(path)) { delete macho; return -2; }
    std::string info1, info256, res;
    bool ok = macho->Sign(&asset, /*bForce*/ true, bundleId, info1, info256, res);
    delete macho;
    return ok ? 0 : -3;
}
