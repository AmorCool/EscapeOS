import Foundation
import CryptoKit

/// Mach-O dylib 设备端 ad-hoc 签名重建器（v0.3.93）。
///
/// 背景（2026-09-02 实测）：
/// 1. module-esc edge 的 openlist.dylib（135MB）经 dlopen 被内核拒——"code signature
///    invalid"。本地逐页校验确认：**CodeDirectory 页哈希与文件内容失配 32755/32868**。
/// 2. iOS 无 codesign、无法 spawn 进程 → App 内置签名重建器：
///    **抛弃原 SuperBlob，从零构建一份干净 ad-hoc 签名**（SHA256/4096 页、无特殊槽、
///    codeLimit = 签名偏移），原地写回签名槽（新签名更短，余量清零）。
/// 3. ad-hoc 无身份，仅内容完整性；能否加载取决于 LC 环境的 AMFI（v0.3.73 旧 dylib
///    同法签名且加载成功 → 本环境放行 ad-hoc）。
///
/// 内存策略：逐页流式 SHA256（不整读 135MB）；仅改 header 的 datasize + 签名槽区。
enum MachoReSign {
    enum ReSignError: Error, LocalizedError {
        case notMachO64
        case noCodeSignatureSlot
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .notMachO64: return "不是 64 位 Mach-O"
            case .noCodeSignatureSlot: return "未找到 LC_CODE_SIGNATURE"
            case .ioFailure(let m): return "文件读写失败: \(m)"
            }
        }
    }

    /// 重建 ad-hoc 签名（代码页 SHA256，codeLimit = 签名偏移）。
    static func refreshCodeSignature(at url: URL) throws {
        let PAGE = 4096
        let HASH = 32

        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ReSignError.ioFailure("打开失败") }
        defer { try? fh.close() }
        let head = try fh.readData(ofLength: 64 * 1024)
        func le32(_ o: Int, in d: Data) -> UInt32 { d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) } }
        guard le32(0, in: head) == 0xfeedfacf else { throw ReSignError.notMachO64 }
        let ncmds = Int(le32(16, in: head))

        // 找 LC_CODE_SIGNATURE（记录 datasize 字段绝对偏移以便回写）
        var sigOff = -1
        var sigSize = 0
        var datasizeField = -1
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= head.count else { break }
            let cmd = Int(le32(cursor, in: head))
            let cmdSize = Int(le32(cursor + 4, in: head))
            guard cmdSize >= 8 else { break }
            if cmd == 0x1d {
                sigOff = Int(le32(cursor + 8, in: head))
                sigSize = Int(le32(cursor + 12, in: head))
                datasizeField = cursor + 12
                break
            }
            cursor += cmdSize
        }
        guard sigOff > 0, sigSize >= 4096, datasizeField >= 0 else { throw ReSignError.noCodeSignatureSlot }
        let codeLimit = sigOff
        let nCodePages = Int((codeLimit + PAGE - 1) / PAGE)

        // 读旧 identifier（保持模块身份稳定）；失败用默认名
        var identifier = "openlist.dylib"
        do {
            fh.seek(toFileOffset: UInt64(sigOff))
            if let blob = try? fh.readData(ofLength: min(sigSize, 1024)), blob.count >= 48 {
                func be32(_ o: Int, in d: Data) -> Int {
                    (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
                }
                let count = be32(8, in: blob)
                for i in 0..<min(count, 8) {
                    let typ = be32(12 + i * 8, in: blob) & 0xffffff
                    let off = be32(12 + i * 8 + 4, in: blob)
                    if typ == 0, off + 48 <= blob.count {
                        let identOff = be32(off + 20, in: blob)
                        let start = off + identOff
                        if start < blob.count {
                            var end = start
                            while end < blob.count && blob[end] != 0 { end += 1 }
                            if end > start {
                                identifier = String(bytes: blob[start..<end], encoding: .utf8) ?? identifier
                            }
                        }
                        break
                    }
                }
            }
        }

        // 布局计算（全部偏移相对各结构体起始）
        let cdHeader = 52                        // v0x20400 头部：40 + scatter(4) + team(4) + 补齐
        var hashOffset = cdHeader
        if hashOffset % 4 != 0 { hashOffset += 4 - hashOffset % 4 }
        let idLen = identifier.utf8.count + 1
        // CodeDirectory 内 identOffset（相对 cd）= hashOffset + nCodePages*32
        let cdIdentRel = hashOffset + nCodePages * HASH
        let cdLen = cdIdentRel + idLen
        let blobLen = 12 + 8 + cdLen            // SuperBlob 头(12) + index[0](8) + CD
        guard blobLen <= sigSize else {
            throw ReSignError.ioFailure("新签名 \(blobLen)B 超出原槽 \(sigSize)B")
        }

        // ---- 组装 SuperBlob + CodeDirectory（大端）----
        var b = [UInt8]()
        func w32(_ v: Int) { b.append(UInt8((v >> 24) & 0xff)); b.append(UInt8((v >> 16) & 0xff)); b.append(UInt8((v >> 8) & 0xff)); b.append(UInt8(v & 0xff)) }
        // SuperBlob @0
        w32(0xfade0cc0)
        w32(0)                    // length 占位 → b[4..8]
        w32(1)                    // count
        // index[0] @12
        w32(0)                    // type = CSSLOT_CODEDIRECTORY
        w32(20)                   // offset（CD 起始 @20）
        // CodeDirectory @20
        w32(0xfade0c02)
        w32(0)                    // length 占位 → b[24..28]
        w32(0x20400)              // version
        w32(0)                    // flags
        w32(hashOffset)           // hashOffset（相对 cd）
        w32(cdIdentRel)           // identOffset（相对 cd，先占位同值）
        w32(0)                    // nSpecialSlots
        w32(nCodePages)           // nCodeSlots
        w32(codeLimit)            // codeLimit
        b.append(32)              // hashSize
        b.append(2)               // hashType = SHA256
        b.append(0)               // platform
        b.append(12)              // pageSize log2
        w32(0)                    // spare2
        w32(0)                    // scatterOffset
        w32(0)                    // teamOffset
        while b.count < 20 + hashOffset { b.append(0) }   // 对齐填充至哈希区

        // 流式哈希代码页 [0, codeLimit)
        fh.seek(toFileOffset: 0)
        for _ in 0..<nCodePages {
            let remaining = codeLimit - Int(fh.offsetInFile)
            guard remaining > 0 else { break }
            let toRead = min(PAGE, remaining)
            let chunk = try fh.readData(ofLength: toRead)
            guard chunk.count == toRead else { throw ReSignError.ioFailure("读页失败 @\(fh.offsetInFile)") }
            b.append(contentsOf: SHA256.hash(data: chunk))
        }
        // identifier（紧跟哈希区）
        b.append(contentsOf: Array(identifier.utf8))
        b.append(0)

        // 回填长度
        func p32(_ at: Int, _ v: Int) { b[at] = UInt8((v >> 24) & 0xff); b[at+1] = UInt8((v >> 16) & 0xff); b[at+2] = UInt8((v >> 8) & 0xff); b[at+3] = UInt8(v & 0xff) }
        p32(4, b.count)                     // SuperBlob.length
        p32(24, cdLen)                      // cd.length（b[24]=cd 起始+4）
        p32(40, cdIdentRel)                 // cd.identOffset 最终值（b[40] = cd 起始20 + 20）

        guard b.count <= sigSize else { throw ReSignError.ioFailure("blob 尺寸异常") }

        // ---- 写回 ----
        guard let wh = try? FileHandle(forWritingTo: url) else { throw ReSignError.ioFailure("写打开失败") }
        defer { try? wh.close() }
        wh.seek(toFileOffset: UInt64(datasizeField))
        var szBE = UInt32(b.count).bigEndian
        try? wh.write(contentsOf: Data(bytes: &szBE, count: 4))
        wh.seek(toFileOffset: UInt64(sigOff))
        try? wh.write(contentsOf: Data(b))
        if b.count < sigSize {
            wh.seek(toFileOffset: UInt64(sigOff + b.count))
            try? wh.write(contentsOf: Data(repeating: 0, count: sigSize - b.count))
        }
        try? wh.synchronize()
        print("[MachoReSign] ad-hoc 签名重建完成 pages=\(nCodePages) len=\(b.count)/\(sigSize) id=\(identifier)")
    }
}
