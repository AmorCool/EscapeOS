import Foundation
import Compression

/// v0.3.300：本地 IPA 包检测（FairPlay 加密 / Bundle 信息）
///
/// **为什么需要它**：App Store 原始下载的 IPA 是 **FairPlay 加密**的
/// （主二进制 Mach-O 的 `LC_ENCRYPTION_INFO_64.cryptid == 1`）。这种包**只能在
/// 有解密密钥的设备上装**（即走 App Store 正规安装流程）；用 Apple ID 重签只能
/// 替换 `embedded.mobileprovision` 与重做 `_CodeSignature`，**不会解密 `__TEXT`**，
/// 装上去必然校验失败。所以下载后必须先判定，再决定怎么装 —— 而不是盲目塞给 installd。
///
/// 判据来自 Mach-O 加载命令：
///   - `LC_ENCRYPTION_INFO`    (0x21, 32 位)
///   - `LC_ENCRYPTION_INFO_64` (0x2C, 64 位)
///   cryptid = 0 → 已解密（可重签/可直接装）；cryptid = 1 → FairPlay 加密。
///
/// 实现只用 Foundation + Compression：zip 的 method 8 就是 raw DEFLATE
/// （`COMPRESSION_ZLIB`），`compression_decode_buffer` 允许只解出所需前若干字节，
/// 因此**不必**把几百 MB 的主二进制整个展开。
enum IPAPackageInspector {

    struct Inspection {
        var bundleIdentifier: String?
        var bundleVersion: String?
        var displayName: String?
        var executable: String?
        /// 主二进制是否 FairPlay 加密
        var isEncrypted: Bool
        /// 原始 cryptid（0 = 明文）
        var cryptid: UInt32
        /// 加密段长度（cryptsize）
        var cryptSize: UInt32
        /// 主二进制文件名缺失（打包异常）
        var missingExecutable: Bool = false

        var summary: String {
            isEncrypted ? "FairPlay 加密（cryptid=1，cryptsize=\(cryptSize)）" : "已解密（cryptid=0）"
        }
    }

    // MARK: - 对外

    /// 完整检测（解 Info.plist + 读主二进制 cryptid）
    static func inspect(ipaPath: String) -> Inspection? {
        guard let fh = FileHandle(forReadingAtPath: ipaPath) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 1024 else { return nil }

        guard let entries = centralDirectory(fh: fh, fileSize: size) else { return nil }
        guard let infoEntry = entries.first(where: {
            $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist")
        }), let infoData = readEntry(fh: fh, entry: infoEntry, maxBytes: 1 << 20),
           let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
           let info = plist as? [String: Any] else {
            return nil
        }

        let bundleId = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String
        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        let exe = info["CFBundleExecutable"] as? String

        var result = Inspection(bundleIdentifier: bundleId,
                                bundleVersion: version,
                                displayName: display,
                                executable: exe,
                                isEncrypted: false,
                                cryptid: 0,
                                cryptSize: 0,
                                missingExecutable: exe == nil)
        guard let exe, let appPrefix = infoEntry.name.components(separatedBy: ".app/").first else {
            return result
        }
        let exePath = appPrefix + ".app/" + exe
        guard let exeEntry = entries.first(where: { $0.name == exePath }),
              // 只解前 8KB：Mach-O 头 + 加载命令足够
              let head = readEntry(fh: fh, entry: exeEntry, maxBytes: 8192),
              let enc = encryptionInfo(from: head) else {
            result.missingExecutable = true
            return result
        }
        result.missingExecutable = false
        result.cryptid = enc.cryptid
        result.cryptSize = enc.cryptSize
        result.isEncrypted = enc.cryptid != 0
        return result
    }

    /// 快速判定是否 FairPlay 加密（nil = 读不出来）
    static func isFairPlayEncrypted(ipaPath: String) -> Bool? {
        inspect(ipaPath: ipaPath)?.isEncrypted
    }

    // MARK: - 提取安装所需的 sidecar（sinf / iTunesMetadata）

    /// 提取 `Payload/<name>.app/SC_Info/<CFBundleExecutable>.sinf`
    ///
    /// 这是 installd 安装 App Store（加密）应用时必须的 `ApplicationSINF` 载荷：
    /// installd 拿它向 Apple 请求该设备的解密密钥。**没有 sinf 就装不了加密包。**
    static func extractSINF(ipaPath: String) -> Data? {
        extract(ipaPath: ipaPath, suffixProvider: { exe, appPrefix in
            "\(appPrefix).app/SC_Info/\(exe).sinf"
        })
    }

    /// 提取 `Payload/<name>.app/iTunesMetadata.plist`（作为安装选项 `iTunesMetadata`）
    static func extractiTunesMetadata(ipaPath: String) -> Data? {
        extract(ipaPath: ipaPath, suffixProvider: { _, appPrefix in
            "\(appPrefix).app/iTunesMetadata.plist"
        }, maxBytes: 4 << 20)
    }

    /// 按 Info.plist 推导出目标路径后取条目内容
    private static func extract(ipaPath: String,
                                suffixProvider: (_ executable: String, _ appPrefix: String) -> String,
                                maxBytes: Int = 1 << 20) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: ipaPath) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 1024, let entries = centralDirectory(fh: fh, fileSize: size) else { return nil }
        guard let infoEntry = entries.first(where: {
            $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist")
        }), let infoData = readEntry(fh: fh, entry: infoEntry, maxBytes: 1 << 20),
           let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
           let info = plist as? [String: Any],
           let exe = info["CFBundleExecutable"] as? String,
           let appPrefix = infoEntry.name.components(separatedBy: ".app/").first else {
            return nil
        }
        let target = suffixProvider(exe, appPrefix)
        guard let e = entries.first(where: { $0.name == target }) else { return nil }
        return readEntry(fh: fh, entry: e, maxBytes: maxBytes)
    }

    // MARK: - Mach-O

    /// 解析 Mach-O 头部的加密加载命令
    static func encryptionInfo(from data: Data) -> (cryptid: UInt32, cryptSize: UInt32)? {
        guard data.count >= 32 else { return nil }
        let magic = u32(data, 0)
        let is64: Bool
        switch magic {
        case 0xFEEDFACF, 0xCFFAEDFE: is64 = true       // MH_MAGIC_64 / 大端
        case 0xFEEDFACE, 0xCEFAEDFE: is64 = false      // MH_MAGIC
        case 0xCAFEBABE, 0xBEBAFECA: return nil        // FAT，需另处理（IPA 内一般非 fat）
        default: return nil
        }
        _ = is64
        let ncmds = Int(u32(data, 16))
        var p = 32
        for _ in 0..<ncmds {
            guard p + 8 <= data.count else { break }
            let cmd = u32(data, p)
            let cmdsize = Int(u32(data, p + 4))
            if cmd == 0x2C || cmd == 0x21 {            // LC_ENCRYPTION_INFO(_64)
                guard p + 20 <= data.count else { break }
                let cryptSize = u32(data, p + 12)
                let cryptid = u32(data, p + 16)
                return (cryptid, cryptSize)
            }
            guard cmdsize >= 8 else { break }
            p += cmdsize
        }
        // 没有加密命令 = 明文
        return (0, 0)
    }

    // MARK: - ZIP（只读中央目录 + 按需解压前 N 字节）

    private struct Entry {
        var name: String
        var method: Int
        var compSize: Int64
        var uncompSize: Int64
        var localOffset: Int64
    }

    private static func centralDirectory(fh: FileHandle, fileSize: UInt64) -> [Entry]? {
        let tailLen = Int(min(fileSize, 65558))
        try? fh.seek(toOffset: fileSize - UInt64(tailLen))
        guard let tail = try? fh.read(upToCount: tailLen), tail.count >= 22 else { return nil }
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let cdSize = Int(u32(tail, e + 12))
        let cdOffset = UInt64(u32(tail, e + 16))
        guard cdSize > 0, cdSize < 64 * 1024 * 1024 else { return nil }
        try? fh.seek(toOffset: cdOffset)
        guard let cd = try? fh.read(upToCount: cdSize) else { return nil }

        var out: [Entry] = []
        var p = 0
        while p + 46 <= cd.count {
            guard u32(cd, p) == 0x02014b50 else { break }
            let method = Int(u16(cd, p + 10))
            let compSize = Int64(u32(cd, p + 20))
            let uncompSize = Int64(u32(cd, p + 24))
            let nameLen = Int(u16(cd, p + 28))
            let extraLen = Int(u16(cd, p + 30))
            let commentLen = Int(u16(cd, p + 32))
            let localOffset = Int64(u32(cd, p + 42))
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(data: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)),
                              encoding: .utf8) ?? ""
            out.append(Entry(name: name, method: method, compSize: compSize,
                             uncompSize: uncompSize, localOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out.isEmpty ? nil : out
    }

    /// 读取条目内容（最多 `maxBytes` 字节；deflate 只解出所需部分）
    private static func readEntry(fh: FileHandle, entry: Entry, maxBytes: Int) -> Data? {
        try? fh.seek(toOffset: UInt64(max(0, entry.localOffset)))
        guard let lh = try? fh.read(upToCount: 30), lh.count == 30, u32(lh, 0) == 0x04034b50 else {
            return nil
        }
        let nameLen = Int(u16(lh, 26))
        let extraLen = Int(u16(lh, 28))
        let dataOffset = entry.localOffset + 30 + Int64(nameLen) + Int64(extraLen)

        switch entry.method {
        case 0:
            let want = min(Int(entry.compSize), maxBytes)
            try? fh.seek(toOffset: UInt64(dataOffset))
            return try? fh.read(upToCount: want)
        case 8:
            // 只读压缩数据的前若干字节即可解出开头（deflate 是流式）
            let wantComp = min(Int(entry.compSize), max(1 << 20))
            try? fh.seek(toOffset: UInt64(dataOffset))
            guard let comp = try? fh.read(upToCount: wantComp), !comp.isEmpty else { return nil }
            return inflatePrefix(comp, maxOut: maxBytes)
        default:
            return nil
        }
    }

    /// raw DEFLATE 解压，只取前 `maxOut` 字节
    private static func inflatePrefix(_ input: Data, maxOut: Int) -> Data? {
        var out = Data(count: maxOut)
        let written: Int = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, maxOut, srcBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    // MARK: - 小工具

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt32(d[b])
            | (UInt32(d[b + 1]) << 8)
            | (UInt32(d[b + 2]) << 16)
            | (UInt32(d[b + 3]) << 24)
    }
}
