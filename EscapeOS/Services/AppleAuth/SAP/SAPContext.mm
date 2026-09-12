#import "SAPContext.h"
#import <CommonCrypto/CommonDigest.h>
#include "SapMachine.h"
#include <cstring>
#include <string>

// ─────────────────────────────────────────────────────────────────────────────
//  资产校验（EscapeOS 改动，见本文件末尾说明）
//
//  官方实现按「长度 + SHA-256」严格校验 CoreFP / CommerceKit / CommerceCore /
//  CoreFP.icxs。但在侧载宿主（LiveContainer / ipaside 等）里，宿主会给 app 包内
//  所有 Mach-O 重新签名来换取运行权限 —— 代码签名是**追加**到文件尾部的，于是资产
//  长度比官方值大（v0.3.324 实测：CoreFP 29,014,912 → 29,294,592，+279,680，
//  恰好是一个代码签名；文件内容区未变、依旧可被 Unicorn 解释）。
//
//  因此这里分三条路：
//    · 长度与官方值一致 → 按官方 SHA-256 严格校验
//    · 长度更大         → 放行，说明写入 assetNotes 供上层日志（重签/壳）
//    · 长度更小         → 判为缺失或截断（打包/下载出错）
// ─────────────────────────────────────────────────────────────────────────────

static NSMutableArray<NSString *> *AssetNotes(void) {
    static NSMutableArray<NSString *> *notes = [NSMutableArray array];
    return notes;
}

/// 描述尾部多出来的字节：若确为追加的代码签名则说明清楚，否则只报字节数。
///
/// ⚠️ v0.3.332：**必须支持 fat（universal）二进制**。官方资产里
/// `CoreFP` 与 `CommerceCore` 都是 fat（magic `0xCAFEBABE`，2 个切片），
/// 只有 `CommerceKit` 是 thin Mach-O 64。老实现只认 thin 头，
/// 于是 fat 的那两个被误报成「不是可识别的代码签名」（用户看到日志后当场指出）。
/// 现在：先定位 x86_64 切片，再在切片内数载入命令找 LC_CODE_SIGNATURE。
static NSString *DescribeExtraBytes(NSData *data, NSUInteger expectedSize) {
    uint64_t extra = (uint64_t)data.length - (uint64_t)expectedSize;
    const uint8_t *p = static_cast<const uint8_t *>(data.bytes);
    NSUInteger length = data.length;
    if (length < 8) return [NSString stringWithFormat:@"尾部 +%llu B（文件过短）", extra];

    auto readBE = [](const uint8_t *q) -> uint32_t {
        return (uint32_t(q[0]) << 24) | (uint32_t(q[1]) << 16) | (uint32_t(q[2]) << 8) | uint32_t(q[3]);
    };
    auto readLE = [](const uint8_t *q) -> uint32_t {
        return (uint32_t(q[3]) << 24) | (uint32_t(q[2]) << 16) | (uint32_t(q[1]) << 8) | uint32_t(q[0]);
    };

    // ① 定位 Mach-O 头：fat 取 x86_64 切片（找不到就取第一个切片）
    NSUInteger sliceBase = 0;
    NSString *prefix = @"";
    if (readBE(p) == 0xCAFEBABE) {
        uint32_t nfat = readBE(p + 4);
        if (nfat > 0 && nfat < 64 && length >= 8u + (NSUInteger)nfat * 20u) {
            NSUInteger first = NSUIntegerMax;
            NSUInteger chosen = NSUIntegerMax;
            for (uint32_t i = 0; i < nfat; i++) {
                const uint8_t *arch = p + 8 + (NSUInteger)i * 20;
                uint32_t cputype = readBE(arch);
                uint32_t offset = readBE(arch + 8);
                if (first == NSUIntegerMax) first = offset;
                if (cputype == 0x01000007) { chosen = offset; break; }
            }
            if (chosen == NSUIntegerMax) chosen = first;
            if (chosen != NSUIntegerMax && chosen < length) {
                sliceBase = chosen;
                prefix = [NSString stringWithFormat:@"fat 二进制 %u 切片 · ", nfat];
            }
        }
    }
    const uint8_t *m = p + sliceBase;
    NSUInteger avail = length - sliceBase;
    uint32_t magic = avail >= 4 ? readLE(m) : 0;
    if (magic != 0xFEEDFACF && magic != 0xFEEDFACE) {
        return [NSString stringWithFormat:@"尾部 +%llu B（%@不是 Mach-O，无法识别）", extra, prefix];
    }

    // ② 在 thin（或切片）内数载入命令
    if (avail < 32) return [NSString stringWithFormat:@"尾部 +%llu B（%@Mach-O 头不全）", extra, prefix];
    uint32_t ncmds = readLE(m + 16);
    NSUInteger off = (magic == 0xFEEDFACF) ? 32 : 28;
    for (uint32_t i = 0; i < ncmds && off + 8 <= avail; i++) {
        uint32_t cmd = readLE(m + off);
        uint32_t cmdsize = readLE(m + off + 4);
        if (cmdsize < 8 || off + cmdsize > avail) break;
        if (cmd == 0x1d /* LC_CODE_SIGNATURE */ && cmdsize >= 16) {
            uint32_t dataoff = readLE(m + off + 8);
            uint32_t datasize = readLE(m + off + 12);
            uint64_t sigStart = (uint64_t)sliceBase + (uint64_t)dataoff;
            if (sigStart + (uint64_t)datasize == (uint64_t)length) {
                return [NSString stringWithFormat:@"尾部 +%llu B 为代码签名（%@侧载宿主重签）", extra, prefix];
            }
            return [NSString stringWithFormat:@"尾部 +%llu B（%@签名 %u B @ %llu）", extra, prefix, datasize, sigStart];
        }
        off += cmdsize;
    }
    return [NSString stringWithFormat:@"尾部 +%llu B（%@未找到代码签名命令）", extra, prefix];
}

static std::vector<uint8_t> ReadVerifiedAsset(NSURL *root, NSString *name, NSUInteger size, NSString *hash) {
    NSURL *file = [root URLByAppendingPathComponent:name];
    NSData *data = [NSData dataWithContentsOfURL:file];
    NSString *path = file.path ?: @"<nil>";
    if (data.length < size) {
        throw std::runtime_error(
            std::string("Missing or truncated SAP asset: ") + name.UTF8String +
            " expected " + std::to_string(size) + " bytes, got " +
            std::to_string((unsigned long long)data.length) + " (" + path.UTF8String + ")");
    }
    if (data.length == size) {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *actual = [NSMutableString string];
        for (unsigned char byte : digest) [actual appendFormat:@"%02x", byte];
        if (![actual isEqualToString:hash]) {
            throw std::runtime_error(
                std::string("SAP asset integrity check failed: ") + name.UTF8String +
                " sha256 " + actual.UTF8String + " != " + hash.UTF8String + " (" + path.UTF8String + ")");
        }
    } else {
        NSString *note = [NSString stringWithFormat:@"%@ %@", name, DescribeExtraBytes(data, size)];
        @synchronized([SAPContext class]) { [AssetNotes() addObject:note]; }
    }
    auto bytes = static_cast<const uint8_t *>(data.bytes);
    return {bytes, bytes + data.length};
}

static void SetError(NSError **error, const std::exception &exception) {
    if (error) *error = [NSError errorWithDomain:@"Asspp.SAP" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:exception.what()]}];
}

@implementation SAPContext {
    std::unique_ptr<SapMachine> _machine;
    std::vector<uint8_t> _hardwareID;
    uint64_t _context;
    BOOL _complete;
    NSUInteger _exchanges;
}

+ (NSString *)assetNotes {
    @synchronized(self) {
        NSMutableArray<NSString *> *notes = AssetNotes();
        return notes.count ? [notes componentsJoinedByString:@"；"] : @"";
    }
}

- (instancetype)initWithAssetsURL:(NSURL *)url hardwareID:(NSData *)hardwareID error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @synchronized([SAPContext class]) { [AssetNotes() removeAllObjects]; }
    try {
        if (hardwareID.length != 6) throw std::runtime_error("Invalid SAP device identifier.");
        auto bytes = static_cast<const uint8_t *>(hardwareID.bytes);
        _hardwareID.assign(bytes, bytes + hardwareID.length);
        _machine = SapMachine::Create(
            ReadVerifiedAsset(url, @"CoreFP", 29014912, @"f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074"),
            ReadVerifiedAsset(url, @"CommerceCore", 207744, @"c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2"),
            ReadVerifiedAsset(url, @"CommerceKit", 3271840, @"b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2"),
            ReadVerifiedAsset(url, @"CoreFP.icxs", 5288352, @"473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a"),
            _hardwareID
        );
        _context = _machine->Initialize(_hardwareID);
        return self;
    } catch (const std::exception &exception) {
        SetError(error, exception);
        return nil;
    }
}

- (BOOL)complete { return _complete; }

- (NSData *)exchangeData:(NSData *)data version:(uint32_t)version error:(NSError **)error {
    try {
        if (!_machine || version != 200 || _exchanges >= 2 || !data.length || data.length > 1024 * 1024)
            throw std::runtime_error("Invalid SAP handshake.");
        auto [output, state] = _machine->Exchange(version, _hardwareID, _context, {static_cast<const uint8_t *>(data.bytes), data.length});
        if (state != (_exchanges == 0 ? 1 : 0)) throw std::runtime_error("Unexpected SAP handshake state.");
        _exchanges++;
        _complete = state == 0;
        return [NSData dataWithBytes:output.data() length:output.size()];
    } catch (const std::exception &exception) {
        SetError(error, exception);
        return nil;
    }
}

- (NSData *)signData:(NSData *)data error:(NSError **)error {
    try {
        if (!_complete || data.length > 1024 * 1024) throw std::runtime_error("SAP session is not ready.");
        auto signature = _machine->Sign(_context, {static_cast<const uint8_t *>(data.bytes), data.length});
        if (signature.empty()) throw std::runtime_error("SAP returned an empty signature.");
        return [NSData dataWithBytes:signature.data() length:signature.size()];
    } catch (const std::exception &exception) {
        SetError(error, exception);
        return nil;
    }
}

- (void)dealloc {
    if (_machine && _context) {
        try { _machine->Teardown(_context); } catch (...) { /* Destructors must not throw. */ }
    }
}
@end
