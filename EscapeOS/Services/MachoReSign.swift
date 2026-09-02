import Foundation
import CryptoKit

/// Mach-O dylib 设备端 ad-hoc 重签名器（v0.3.91）。
///
/// 背景（2026-09-02 实测）：模块 dylib 从 module-esc edge 下载导入后 dlopen 被内核
/// 拒绝——"code signature invalid"（签名 blob 存在但页哈希与文件内容不匹配）。
/// iOS 无 codesign 工具、无法 spawn 进程，因此在 App 内置最小重签名器：
/// **保留 codesign 已写好的 CodeDirectory 结构（identifier/flags/版本/槽布局不动），
/// 仅重算全部页哈希（SHA256）并原位写回。**
///
/// 身份说明：ad-hoc 签名**无任何开发者身份**，只保证内容完整性；能否被内核接受
/// 取决于宿主环境的 AMFI 策略（LC 环境已实证放行 ad-hoc——v0.3.73 旧 dylib 加载成功）。
///
/// 内存策略：逐页流式哈希（不整读 137MB）；仅重写 blob 内的哈希区（~1MB）。
enum MachoReSign {
    enum ReSignError: Error, LocalizedError {
        case notMachO64
        case noCodeSignatureSlot
        case badSuperBlob
        case noCodeDirectory
        case unsupportedHashType
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .notMachO64: return "不是 64 位 Mach-O 文件"
            case .noCodeSignatureSlot: return "未找到 LC_CODE_SIGNATURE（文件无签名槽）"
            case .badSuperBlob: return "SuperBlob 魔数/结构非法"
            case .noCodeDirectory: return "SuperBlob 中无 CodeDirectory"
            case .unsupportedHashType: return "仅支持 SHA256 CodeDirectory"
            case .ioFailure(let m): return "文件读写失败: \(m)"
            }
        }
    }

    /// 刷新指定 Mach-O 文件的 CodeDirectory 页哈希（原位，长度不变）。
    static func refreshCodeSignature(at url: URL) throws {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            throw ReSignError.ioFailure("打开失败")
        }
        defer { try? fh.close() }

        // ---- 1) mach_header_64 + load commands（读前 32KB 足够）----
        let head = try fh.readData(ofLength: 32 * 1024)
        guard head.count >= 32 else { throw ReSignError.notMachO64 }
        func le32(_ o: Int, in d: Data) -> UInt32 {
            d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }
        }
        guard le32(0, in: head) == 0xfeedfacf else { throw ReSignError.notMachO64 }  // MH_MAGIC_64
        let ncmds = Int(le32(16, in: head))

        var sigOff = -1
        var sigSize = 0
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= head.count else { break }
            let cmd = Int(le32(cursor, in: head))
            let cmdSize = Int(le32(cursor + 4, in: head))
            guard cmdSize >= 8 else { break }
            if cmd == 0x1d {   // LC_CODE_SIGNATURE
                sigOff = Int(le32(cursor + 8, in: head))
                sigSize = Int(le32(cursor + 12, in: head))
                break
            }
            cursor += cmdSize
        }
        guard sigOff > 0, sigSize > 0, sigSize <= 8 * 1024 * 1024 else {
            throw ReSignError.noCodeSignatureSlot
        }

        // ---- 2) SuperBlob → CodeDirectory（big-endian 字段）----
        fh.seek(toFileOffset: UInt64(sigOff))
        guard let blob = try? fh.readData(ofLength: sigSize), blob.count == sigSize else {
            throw ReSignError.ioFailure("读 blob")
        }
        func be32(_ o: Int, in d: Data) -> Int {
            (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
        }
        guard be32(0, in: blob) == 0xfade0cc0 else { throw ReSignError.badSuperBlob }
        let slotCount = be32(4, in: blob)
        var cd = -1   // CodeDirectory 在 blob 内的相对偏移
        for i in 0..<slotCount {
            let typ = be32(8 + i * 8, in: blob) & 0xffff
            let off = be32(8 + i * 8 + 4, in: blob)
            if typ == 0 { cd = off; break }   // CSSLOT_CODEDIRECTORY
        }
        guard cd >= 0, cd + 44 <= blob.count else { throw ReSignError.noCodeDirectory }
        let cdMagic = be32(cd, in: blob)
        guard cdMagic == 0xfade0c02 || cdMagic == 0xfade0c01 else { throw ReSignError.noCodeDirectory }

        let hashOffset = be32(cd + 16, in: blob)       // 哈希区起点（相对 cd）
        let nSpecialSlots = be32(cd + 24, in: blob)
        let nCodeSlots = be32(cd + 28, in: blob)
        let codeLimit = be32(cd + 32, in: blob)
        let hashSize = Int(blob[cd + 36])              // SHA256 = 32
        let hashType = Int(blob[cd + 37])              // 2 = SHA256
        let pageSizeLog2 = Int(blob[cd + 39])          // 通常 12（4096）
        guard hashSize == 32, hashType == 2, (1...24).contains(pageSizeLog2),
              nCodeSlots > 0, codeLimit > 0 else { throw ReSignError.unsupportedHashType }
        let pageSize = 1 << pageSizeLog2
        guard cd + hashOffset + nSpecialSlots * hashSize + nCodeSlots * hashSize <= sigSize else {
            throw ReSignError.badSuperBlob             // 哈希区越界 = 结构异常，不写
        }

        // ---- 3) 流式重算代码页哈希：SHA256(file[page]) 覆盖 [0, codeLimit) ----
        guard let rh = try? FileHandle(forReadingFrom: url) else { throw ReSignError.ioFailure("读文件") }
        defer { try? rh.close() }
        rh.seek(toFileOffset: 0)
        var codeHashes = [UInt8]()
        codeHashes.reserveCapacity(nCodeSlots * hashSize)
        var remaining = codeLimit
        while remaining > 0 {
            let len = min(pageSize, remaining)
            guard let page = try? rh.readData(ofLength: len), page.count == len else {
                throw ReSignError.ioFailure("读页失败")
            }
            codeHashes.append(contentsOf: SHA256.hash(data: page))
            remaining -= len
        }

        // ---- 4) 特殊槽（负索引）：紧贴 codeLimit 之前的页，从 -1 往前 ----
        var specialHashes = [UInt8]()
        if nSpecialSlots > 0 {
            specialHashes.reserveCapacity(nSpecialSlots * hashSize)
            for i in 1...nSpecialSlots {
                let end = codeLimit - (i - 1) * pageSize
                let start = codeLimit - i * pageSize
                guard start >= 0, end > start else {
                    specialHashes.append(contentsOf: [UInt8](repeating: 0, count: hashSize))
                    continue
                }
                rh.seek(toFileOffset: UInt64(start))
                guard let page = try? rh.readData(ofLength: end - start) else {
                    specialHashes.append(contentsOf: [UInt8](repeating: 0, count: hashSize))
                    continue
                }
                specialHashes.append(contentsOf: SHA256.hash(data: page))
            }
        }

        // ---- 5) 原位替换 blob 内的哈希区（identifier/team 等尾部一字节不动）----
        guard let wh = try? FileHandle(forWritingTo: url) else { throw ReSignError.ioFailure("写打开") }
        defer { try? wh.close() }
        if specialHashes.count > 0 {
            let specialStart = sigOff + cd + hashOffset - specialHashes.count
            wh.seek(toFileOffset: UInt64(specialStart))
            try? wh.write(contentsOf: Data(specialHashes))
        }
        let codeStart = sigOff + cd + hashOffset + specialHashes.count
        wh.seek(toFileOffset: UInt64(codeStart))
        try? wh.write(contentsOf: Data(codeHashes))
        try? wh.synchronize()

        // 触发文件的元数据更新（避免内核/缓存沿用旧校验状态）
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
