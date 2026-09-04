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

// ═════════ v0.3.148：签名内容级诊断 ═════════
// 目的：主程序(exec 校验已过审)与模块 dylib(dlopen 被拒) 的签名字段级对照 +
// CDHash 抽样自检，定位 AMFI 拒绝的确切层（结构/页hash/证书/TeamID）。
// 注意：host(arm64) 与 Mach-O 均为小端，全部字段直接读取，不做字节交换。
#include "common/mach-o.h"
#include <openssl/pkcs7.h>
#include <vector>

static void escDumpBlob(const uint8_t* base, size_t size, uint32_t dataoff,
                        uint32_t datasize, const char* tag,
                        const std::function<void(const std::string&)>& diag) {
    char buf[512];
    if ((uint64_t)dataoff + datasize > size) {
        snprintf(buf, sizeof(buf), "  [%s] ⚠ blob 越界: dataoff=%u datasize=%u filesize=%zu\n",
                 tag, dataoff, datasize, size);
        diag(buf);
        return;
    }
    const uint8_t* sb = base + dataoff;
    uint32_t magic = *(const uint32_t*)(sb);
    uint32_t length = *(const uint32_t*)(sb + 4);
    uint32_t count = *(const uint32_t*)(sb + 8);
    snprintf(buf, sizeof(buf), "  [%s] blob magic=0x%08x length=%u count=%u (cmd datasize=%u)\n",
             tag, magic, length, count, datasize);
    diag(buf);
    if (magic != CSMAGIC_EMBEDDED_SIGNATURE) {
        diag("  ⚠ SuperBlob magic 异常\n");
        return;
    }
    for (uint32_t i = 0; i < count && i < 16; i++) {
        const uint8_t* idx = sb + 12 + i * 8;
        uint32_t type = *(const uint32_t*)idx;
        uint32_t off = *(const uint32_t*)(idx + 4);
        const uint8_t* slot = sb + off;
        uint32_t slotMagic = *(const uint32_t*)slot;
        uint32_t slotLen = *(const uint32_t*)(slot + 4);
        snprintf(buf, sizeof(buf), "    slot[%u] type=0x%x off=%u magic=0x%08x len=%u\n",
                 i, type, off, slotMagic, slotLen);
        diag(buf);
        if (slotMagic == CSMAGIC_CODEDIRECTORY) {
            const CS_CodeDirectory* cd = (const CS_CodeDirectory*)slot;
            std::string ident((const char*)slot + cd->identOffset);
            std::string team;
            if (cd->version >= 0x20200 && cd->teamOffset > 0)
                team = std::string((const char*)slot + cd->teamOffset);
            snprintf(buf, sizeof(buf),
                     "      CD: ver=0x%x flags=0x%x hashSize=%u hashType=%u pageSize=1<<%u\n"
                     "          nSpecial=%u nCode=%u codeLimit=%u ident=\"%.64s\" team=\"%.32s\"\n",
                     cd->version, cd->flags, cd->hashSize, cd->hashType, cd->pageSize,
                     cd->nSpecialSlots, cd->nCodeSlots, cd->codeLimit, ident.c_str(), team.c_str());
            diag(buf);
            // CDHash 抽样自检（SHA256：hashType=2 hashSize=32）
            if (cd->hashType == 2 && cd->hashSize == 32 && (uint64_t)cd->codeLimit <= size) {
                uint32_t pageSz = 1u << cd->pageSize;
                uint32_t nCode = cd->nCodeSlots;
                const uint8_t* hashes = slot + cd->hashOffset;
                int okN = 0, badN = 0;
                uint32_t picks[14];
                int np = 0;
                for (int k = 0; k < 2 && k < (int)nCode; k++) picks[np++] = (uint32_t)k;
                for (int k = 0; k < 10 && np < 12; k++)
                    picks[np++] = (uint32_t)((uint64_t)(nCode - 1) * (k + 1) / 11);
                for (int k = 0; k < 2 && np < 14; k++) picks[np++] = nCode - 1 - (uint32_t)k;
                for (int k = 0; k < np; k++) {
                    uint32_t s = picks[k];
                    if (s >= nCode) continue;
                    uint64_t foff = (uint64_t)s * pageSz;
                    uint32_t chunk = (s == nCode - 1) ? (uint32_t)(cd->codeLimit - foff) : pageSz;
                    if (foff + chunk > size || chunk == 0 || chunk > pageSz) { badN++; continue; }
                    uint8_t h[EVP_MAX_MD_SIZE]; unsigned int hl = 0;
                    EVP_Digest(base + foff, chunk, h, &hl, EVP_sha256(), NULL);
                    if (hl == 32 && 0 == memcmp(h, hashes + (size_t)s * 32, 32)) okN++;
                    else {
                        badN++;
                        snprintf(buf, sizeof(buf), "      ⚠ 页 hash 不匹配 slot#%u (foff=%llu)\n",
                                 s, (unsigned long long)foff);
                        diag(buf);
                    }
                }
                snprintf(buf, sizeof(buf), "      CD256 页hash自检: %d/%d OK (nCode=%u)\n", okN, np, nCode);
                diag(buf);
            }
        } else if (slotMagic == CSMAGIC_BLOBWRAPPER) {
            const uint8_t* der = slot + 8;
            uint32_t derLen = slotLen - 8;
            BIO* bio = derLen > 0 ? BIO_new_mem_buf(der, (int)derLen) : NULL;
            PKCS7* p7 = bio ? d2i_PKCS7_bio(bio, NULL) : NULL;
            if (!p7) {
                diag("      CMS: d2i_PKCS7 解析失败\n");
            } else {
                STACK_OF(X509)* certs = p7->d.sign ? p7->d.sign->cert : NULL;
                int nc = certs ? sk_X509_num(certs) : 0;
                snprintf(buf, sizeof(buf), "      CMS: len=%u 证书数=%d\n", derLen, nc);
                diag(buf);
                for (int c = 0; c < nc && c < 6; c++) {
                    X509* x = sk_X509_value(certs, c);
                    char* s1 = X509_NAME_oneline(X509_get_subject_name(x), NULL, 0);
                    char* s2 = X509_NAME_oneline(X509_get_issuer_name(x), NULL, 0);
                    ASN1_TIME* na = X509_get_notAfter(x);
                    snprintf(buf, sizeof(buf), "        cert[%d] subj=%.160s\n                 issuer=%.160s\n",
                             c, s1 ? s1 : "?", s2 ? s2 : "?");
                    diag(buf);
                    if (na && na->data && na->length > 0 && na->type == V_ASN1_GENERALIZEDTIME) {
                        snprintf(buf, sizeof(buf), "                 notAfter=%.15s\n", (const char*)na->data);
                        diag(buf);
                    } else if (na && na->data && na->length > 0) {
                        snprintf(buf, sizeof(buf), "                 notAfter(utc)=%.13s\n", (const char*)na->data);
                        diag(buf);
                    }
                    OPENSSL_free(s1); OPENSSL_free(s2);
                }
                if (p7->d.sign && p7->d.sign->auth_attr) {
                    snprintf(buf, sizeof(buf), "      CMS signed attrs 数=%d\n",
                             sk_X509_ATTRIBUTE_num(p7->d.sign->auth_attr));
                    diag(buf);
                }
            }
            if (p7) PKCS7_free(p7);
            if (bio) BIO_free(bio);
        }
    }
}

// Mach-O 头 + load commands + 签名 blob 全量诊断
static void escDumpMachO(const std::string& path, const char* tag,
                         const std::function<void(const std::string&)>& diag) {
    char buf[512];
    diag(std::string("[") + tag + "] path=" + path + "\n");
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) {
        snprintf(buf, sizeof(buf), "[%s] 打开失败 errno=%d\n", tag, errno);
        diag(buf);
        return;
    }
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    std::vector<uint8_t> hdr(4096);
    size_t rd = fread(hdr.data(), 1, hdr.size(), fp);
    fclose(fp);
    if (rd < 32) { diag("  文件过小\n"); return; }
    uint32_t magic = *(const uint32_t*)hdr.data();
    snprintf(buf, sizeof(buf), "[%s] size=%ld magic=0x%08x\n", tag, fsize, magic);
    diag(buf);
    if (magic != MH_MAGIC_64) { diag("  非 MH_MAGIC_64（FAT/其他），不深入解析\n"); return; }
    struct mach_header_64 mh;
    memcpy(&mh, hdr.data() + 0, sizeof(mh));
    snprintf(buf, sizeof(buf), "  filetype=%u flags=0x%x ncmds=%u sizeofcmds=%u\n",
             mh.filetype, mh.flags, mh.ncmds, mh.sizeofcmds);
    diag(buf);
    if (mh.sizeofcmds > (64u << 20)) { diag("  sizeofcmds 异常\n"); return; }
    std::vector<uint8_t> lcb(mh.sizeofcmds);
    fp = fopen(path.c_str(), "rb");
    if (!fp) return;
    fseek(fp, 32, SEEK_SET);
    size_t got = fread(lcb.data(), 1, mh.sizeofcmds, fp);
    fclose(fp);
    if (got != mh.sizeofcmds) { diag("  load commands 读取不完整\n"); return; }
    int sigCount = 0;
    uint32_t sigOff = 0, sigSize = 0;
    uint8_t* p = lcb.data();
    long consumed = 0;
    for (uint32_t i = 0; i < mh.ncmds && consumed + 8 <= (long)mh.sizeofcmds; i++) {
        struct load_command lc;
        memcpy(&lc, p, sizeof(lc));
        if (lc.cmdsize < 8) break;
        if (lc.cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command le;
            memcpy(&le, p, sizeof(le));
            snprintf(buf, sizeof(buf), "  LC_CODE_SIGNATURE#%d dataoff=%u datasize=%u\n",
                     ++sigCount, le.dataoff, le.datasize);
            diag(buf);
            sigOff = le.dataoff; sigSize = le.datasize;
        } else if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            memcpy(&seg, p, sizeof(seg));
            snprintf(buf, sizeof(buf), "  SEG \"%.16s\" fileoff=%llu filesize=%llu vmsize=%llu nsects=%u flags=0x%x\n",
                     seg.segname, (unsigned long long)seg.fileoff, (unsigned long long)seg.filesize,
                     (unsigned long long)seg.vmsize, seg.nsects, seg.flags);
            diag(buf);
        }
        p += lc.cmdsize;
        consumed += lc.cmdsize;
    }
    if (sigCount == 0) diag("  （无 LC_CODE_SIGNATURE）\n");
    else if (sigCount > 1) diag("  ⚠ 多个 LC_CODE_SIGNATURE！\n");
    if (sigCount >= 1) {
        int fd = open(path.c_str(), O_RDONLY);
        if (fd >= 0) {
            void* m = mmap(NULL, (size_t)fsize, PROT_READ, MAP_PRIVATE, fd, 0);
            if (m && m != MAP_FAILED) {
                escDumpBlob((const uint8_t*)m, (size_t)fsize, sigOff, sigSize, tag, diag);
                munmap(m, (size_t)fsize);
            } else diag("  mmap 失败，无法解析 blob\n");
            close(fd);
        }
    }
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
    // v0.3.148：先 dump 主程序签名做"过审对照基线"（exec 校验已通过）
    @autoreleasepool {
        NSString* exePath = [NSBundle mainBundle].executablePath;
        if (exePath) {
            escDumpMachO(exePath.fileSystemRepresentation, "主程序(exec过审对照)", diagWrite);
        }
    }
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
        // v0.3.148：签名后独立回读解析（验证落盘 + 结构 + CDHash 自检）
        escDumpMachO(path, "模块dylib(签名后回读)", diagWrite);
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
