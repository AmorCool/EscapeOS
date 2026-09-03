// EscapeOS 桥接：zsign ad-hoc 签名（对齐 LC adhocSignMachOAtPath 的引擎路径）。
// 输入：dylib 路径 + bundleId（可选 entitlements XML）。原文件就地重签
// —— 调用方必须先复制到全新路径（内核按 vnode 缓存校验判决，见 MachoReSign.swift）。
#import <Foundation/Foundation.h>
#include <string.h>
#include "openssl.h"
#include "macho.h"
#include "common/log.h"

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

// ═════════ v0.3.122：开发证书支持（SideStore/AltSign CertificatesManager 同款流程）═════════
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/evp.h>
#include <unistd.h>

// 生成 RSA2048 私钥(PEM) + CSR(PEM)。Apple 免费证书流程与 SideStore/AltSign 一致：
// X509_REQ 用 EVP_sha1 签名（AltSign CertificatesManager.generateCSR 同款）。
// 返回 0 成功；输出 buffer 由调用方 free()。
extern "C" int zsign_gen_key_csr(char** csrPemOut, int* csrPemLen,
                                 char** keyPemOut, int* keyPemLen) {
    if (!csrPemOut || !csrPemLen || !keyPemOut || !keyPemLen) return -2;
    *csrPemOut = NULL; *keyPemOut = NULL;

    BIGNUM* bignum = BN_new();
    RSA* rsa = RSA_new();
    EVP_PKEY* pkey = EVP_PKEY_new();
    X509_REQ* req = X509_REQ_new();
    if (!bignum || !rsa || !pkey || !req) {
        if (bignum) BN_free(bignum);
        if (rsa) RSA_free(rsa);
        if (pkey) EVP_PKEY_free(pkey);
        if (req) X509_REQ_free(req);
        return -1;
    }
    bool ok = BN_set_word(bignum, 65537) == 1
           && RSA_generate_key_ex(rsa, 2048, bignum, NULL) == 1
           && EVP_PKEY_assign_RSA(pkey, rsa) == 1;   // ⚠ assign 转移所有权：此后 pkey 负责
                                                      //    释放 rsa，切勿再 RSA_free（双重释放闪退）
    if (ok) {
        X509_REQ_set_version(req, 0);
        X509_NAME* name = X509_REQ_get_subject_name(req);
        // 主题字段仅占位（Apple 以下发证书为准）
        ok = X509_NAME_add_entry_by_txt(name, "CN", 0x1001 /*MBSTRING_ASC*/,
                                        (const unsigned char*)"EscapeOS", -1, -1, 0) == 1
          && X509_REQ_set_pubkey(req, pkey) == 1
          && X509_REQ_sign(req, pkey, EVP_sha1()) > 0;
    }
    if (ok) {
        BIO* csrBIO = BIO_new(BIO_s_mem());
        BIO* keyBIO = BIO_new(BIO_s_mem());
        ok = PEM_write_bio_X509_REQ(csrBIO, req) == 1
          && PEM_write_bio_PrivateKey(keyBIO, pkey, NULL, NULL, 0, NULL, NULL) == 1;
        if (ok) {
            char* csrPtr = NULL; long csrLen = BIO_get_mem_data(csrBIO, &csrPtr);
            char* keyPtr = NULL; long keyLen = BIO_get_mem_data(keyBIO, &keyPtr);
            if (csrLen > 0 && keyLen > 0) {
                *csrPemOut = (char*)malloc(csrLen + 1);
                *keyPemOut = (char*)malloc(keyLen + 1);
                memcpy(*csrPemOut, csrPtr, csrLen); (*csrPemOut)[csrLen] = 0;
                memcpy(*keyPemOut, keyPtr, keyLen); (*keyPemOut)[keyLen] = 0;
                *csrPemLen = (int)csrLen; *keyPemLen = (int)keyLen;
                ok = true;
            } else ok = false;
        }
        BIO_free(csrBIO); BIO_free(keyBIO);
    }
    BN_free(bignum); EVP_PKEY_free(pkey); X509_REQ_free(req);
    // rsa 已由 EVP_PKEY_assign_RSA 移交给 pkey，EVP_PKEY_free 时一并释放——
    // 这里绝不能再 RSA_free（双重释放 = 点击创建证书即闪退，v0.3.123 实锤）
    return ok ? 0 : -1;
}

// 用真实开发证书（PEM）+ 私钥(PEM) 对 dylib 就地签名（与 SideStore 签的 App 同 TeamID → 库验证通过）
// dbgPath：诊断日志落盘路径（zsign 全部日志 + 分步结果），可为 NULL
extern "C" int zsign_sign_file_with_cert(const char* path,
                                         const char* bundleId,
                                         const char* certPem, int certLen,
                                         const char* keyPem, int keyLen,
                                         const char* entXml, int entLen,
                                         const char* dbgPath) {
    auto diagWrite = [dbgPath](const std::string& text) {
        if (!dbgPath) return;
        FILE* f = fopen(dbgPath, "a");
        if (!f) return;
        fwrite(text.data(), 1, text.size(), f);
        fclose(f);
    };
    diagWrite("\n=== zsign 真证书签名开始 ===\n");
    diagWrite(std::string("target=") + (path ? path : "(null)") + "\n");
    diagWrite(std::string("bundleId=") + (bundleId ? bundleId : "(null)") + "\n");
    if (!path || !bundleId || !certPem || !keyPem) {
        diagWrite("FAIL: 参数为空\n");
        return -2;
    }
    // 写临时文件（ZSignAsset::Init 接收路径）。⚠ 不能用 /tmp——LC 访客沙盒
    // 对 /tmp 无写权限（mkstemp 必败，v0.3.130 实锤「证书/私钥不可用」），用 App 自身 tmp。
    NSString* tmpDir = NSTemporaryDirectory();
    if (!tmpDir) { diagWrite("FAIL: NSTemporaryDirectory 为空\n"); return -2; }
    char certTpl[512], keyTpl[512];
    snprintf(certTpl, sizeof(certTpl), "%sesc-cert-XXXXXX.pem",
             tmpDir.fileSystemRepresentation);
    snprintf(keyTpl,  sizeof(keyTpl),  "%sesc-key-XXXXXX.pem",
             tmpDir.fileSystemRepresentation);
    int cfd = mkstemp(certTpl), kfd = mkstemp(keyTpl);
    if (cfd < 0 || kfd < 0) {
        diagWrite(std::string("FAIL: mkstemp 失败 errno=") + std::to_string(errno) + "\n");
        if (cfd >= 0) close(cfd);
        if (kfd >= 0) close(kfd);
        return -2;
    }
    bool wok = write(cfd, certPem, certLen) == certLen
            && write(kfd, keyPem, keyLen) == keyLen;
    close(cfd); close(kfd);
    if (!wok) {
        unlink(certTpl); unlink(keyTpl);
        diagWrite("FAIL: 临时文件写入失败\n");
        return -2;
    }

    ZLog::logs.clear();
    ZSignAsset asset;
    bool inited = asset.Init(certTpl, keyTpl, "", "", "", /*bAdhoc*/ false,
                             /*bSHA256Only*/ true, /*bSingleBinary*/ true);
    if (!inited) {
        diagWrite("FAIL: ZSignAsset::Init 失败（读取证书/私钥）\n");
        for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
        unlink(certTpl); unlink(keyTpl);
        return -1;
    }
    diagWrite("Init ✓（证书/私钥读取成功）\n");
    ZMachO* macho = new ZMachO();
    if (!macho->Init(path)) {
        delete macho;
        diagWrite("FAIL: ZMachO::Init 失败（解析 dylib）\n");
        for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
        unlink(certTpl); unlink(keyTpl);
        return -2;
    }
    std::string info1, info256, res;
    bool ok = macho->Sign(&asset, /*bForce*/ true, bundleId, info1, info256, res);
    if (!ok) {
        diagWrite("FAIL: Sign 失败\n");
    } else {
        diagWrite("Sign ✓\n");
    }
    for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
    if (!res.empty()) diagWrite("  [res] " + res + "\n");
    delete macho;
    unlink(certTpl); unlink(keyTpl);
    int rc = ok ? 0 : -3;
    diagWrite("=== 签名结束 rc=" + std::to_string(rc) + " ===\n");
    return rc;
}
