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
#include <errno.h>
#include <sys/stat.h>
#include <functional>

// v0.3.146：LC 同款 refreshFile（LiveContainer ZSign/zsign.mm L23-34 逐字对照）——
// copy→remove→rename 回原路径 = 换新 inode，让内核丢弃该 vnode 的旧签名校验缓存。
// LC 原注释：copy, remove and rename back the file to prevent crash due to
// kernel signature cache。缺这步时 dlopen 返回缓存判决（v0.3.145 真机实锤：
// zsign Sign ✓ 后 dlopen 报错与签名前逐字节一致，同一 blobOffset/Size/UUID）。
static bool escRefreshFile(const std::string& path, std::string* err) {
    @autoreleasepool {
        NSString* p = [NSString stringWithUTF8String:path.c_str()];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) {
            if (err) *err = "file not exists";
            return false;
        }
        NSString* tmp = [p stringByAppendingString:@".escsigtmp"];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil]; // 清残留
        NSError* e = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:p toPath:tmp error:&e]) {
            if (err) *err = e.localizedDescription.UTF8String;
            return false;
        }
        e = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:p error:&e]) {
            if (err) *err = e.localizedDescription.UTF8String;
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            return false;
        }
        e = nil;
        if (![NSFileManager.defaultManager moveItemAtPath:tmp toPath:p error:&e]) {
            if (err) *err = e.localizedDescription.UTF8String;
            return false;
        }
        return true;
    }
}

// 签名自证：输出文件 size/mtime，用于真机日志确认落盘与换 inode 生效
static void escStatDiag(const std::string& path, const char* tag,
                        const std::function<void(const std::string&)>& diagWrite) {
    struct stat st;
    memset(&st, 0, sizeof(st));
    if (0 != stat(path.c_str(), &st)) {
        diagWrite(std::string("[") + tag + "] stat 失败 errno=" + std::to_string(errno) + "\n");
        return;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "[%s] size=%lld mtime=%lld\n", tag,
             (long long)st.st_size, (long long)st.st_mtime);
    diagWrite(buf);
}

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

// 验证证书 PEM 与私钥 PEM 是否配对（X509_check_private_key）。
// 返回 1 = 配对，0 = 不配对/解析失败。用于签名前校验与证书创建轮询筛选。
extern "C" int zsign_check_pair(const char* certPem, int certLen,
                                const char* keyPem, int keyLen) {
    if (!certPem || !keyPem || certLen <= 0 || keyLen <= 0) return 0;
    BIO* cbio = BIO_new_mem_buf(certPem, certLen);
    if (!cbio) return 0;
    X509* cert = PEM_read_bio_X509(cbio, NULL, 0, NULL);
    BIO_free(cbio);
    if (!cert) return 0;
    BIO* kbio = BIO_new_mem_buf(keyPem, keyLen);
    if (!kbio) { X509_free(cert); return 0; }
    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(kbio, NULL, NULL, NULL);
    BIO_free(kbio);
    if (!pkey) { X509_free(cert); return 0; }
    int ok = X509_check_private_key(cert, pkey);
    X509_free(cert);
    EVP_PKEY_free(pkey);
    return (ok == 1) ? 1 : 0;
}

// 用真实开发证书（PEM）+ 私钥(PEM) 对 dylib 就地签名（与 SideStore 签的 App 同 TeamID → 库验证通过）
// dbgPath：诊断日志落盘路径（zsign 全部日志 + 分步结果），可为 NULL
extern "C" int zsign_sign_file_with_cert(const char* path,
                                         const char* bundleId,
                                         const char* certPem, int certLen,
                                         const char* keyPem, int keyLen,
                                         const char* entXml, int entLen,
                                         const char* dbgPath,
                                         const char* teamId) {
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

    // v0.3.144：LC 配方（LiveContainer ZSign/zsign.mm signMachOPathArr 同款）——
    // 不传 provision、不嵌 entitlements。真机实锤：dylib 带 entitlements blob
    // （get-task-allow 等）会触发 AMFI 按 App 规则要求 profile 匹配 →
    // code signature invalid errno=1。TeamID 由 openssl.cpp Init 在证书加载后
    // 从证书 OU 直读（GetCertOU，LiveContainer InitSimple L887 同款）。
    diagWrite(std::string("teamId=") + std::string(teamId ? teamId : "(null)")
              + "（LC 配方：无 provision/entitlements，TeamID 取自证书 OU）\n");

    ZLog::logs.clear();
    ZSignAsset asset;
    // v0.3.147：参数对齐 LC。LC InitSimple 不设置 m_bSHA256Only/m_bSingleBinary，
    // 构造默认 false/false → 双 CodeDirectory（SHA1 主 + SHA256 alternate）。
    // iOS AMFI 只接受双目录 blob；v0.3.141-146 传 bSHA256Only=true 生成
    // 单 SHA256 目录 blob（archo.cpp "make it the primary (and only)"）→
    // code signature invalid errno=1（真机 6 版实锤，refreshFile 换 inode 无效
    // 证明非缓存问题）。bSingleBinary 仅影响 MH_EXECUTE 的 execSegFlags，
    // 对 dylib 无效，一并归 false。
    bool inited = asset.Init(certTpl, keyTpl, "", "", "", /*bAdhoc*/ false,
                             /*bSHA256Only*/ false, /*bSingleBinary*/ false);
    if (!inited) {
        diagWrite("FAIL: ZSignAsset::Init 失败（读取证书/私钥）\n");
        for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
        unlink(certTpl); unlink(keyTpl);
        return -1;
    }
    diagWrite("Init ✓（证书/私钥/profile 读取成功）\n");
    // v0.3.146：签名前先换 inode（LC 同款 refreshFile-before），丢掉旧 vnode 缓存判决
    {
        std::string rfErr;
        bool rfBefore = escRefreshFile(path, &rfErr);
        diagWrite(std::string("refreshFile(before)=") + (rfBefore ? "✓" : ("✗ " + rfErr)) + "\n");
        if (!rfBefore) {
            for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
            unlink(certTpl); unlink(keyTpl);
            return -4;
        }
    }
    escStatDiag(path, "签名前", diagWrite);

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
        escStatDiag(path, "签名后", diagWrite);
        // v0.3.146：签名后再换 inode（LC 同款 refreshFile-after）——
        // dlopen 见到全新 vnode 才会重新做签名校验，不吃缓存判决
        std::string rfErr2;
        bool rfAfter = escRefreshFile(path, &rfErr2);
        diagWrite(std::string("refreshFile(after)=") + (rfAfter ? "✓" : ("✗ " + rfErr2)) + "\n");
        if (rfAfter) escStatDiag(path, "refreshFile后", diagWrite);
        ok = rfAfter;
    }
    for (auto& lg : ZLog::logs) diagWrite("  [zlog] " + lg + "\n");
    if (!res.empty()) diagWrite("  [res] " + res + "\n");
    delete macho;
    unlink(certTpl); unlink(keyTpl);
    int rc = ok ? 0 : -3;
    diagWrite("=== 签名结束 rc=" + std::to_string(rc) + " ===\n");
    return rc;
}
