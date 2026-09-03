import Foundation
import CryptoKit

/// Mach-O dylib 设备端 ad-hoc 签名重建器（v0.3.100）。
///
/// 背景（2026-09-02/03 实测链）：
/// 1. module-esc edge 的 openlist.dylib 签名页哈希失配 32755/32868 → 内核拒 dlopen。
/// 2. v0.3.94：CodeDirectory v0x20400 头部实为 88B（spare3/codeLimit64/execSeg*），
///    只写 52B 会让哈希覆盖 codeLimit64/execSeg → 垃圾字段。
/// 3. v0.3.99：flags 必须带 CS_ADHOC(0x2)（无 CMS 时验证器据此走纯哈希路径）。
/// 4. ★ v0.3.100：以上都修好后设备端仍 invalid —— **内核按 vnode 缓存校验判决**：
///    曾被 dlopen 拒过的文件，原地改签名不失效缓存。Nyxian 的解法同款：
///    复制到全新路径（vnode_recover）再签。故本版把重建签名写到**全新文件**。
///
/// 内存策略：流式复制（不整读 135MB）；哈希对新文件逐页计算后回填 blob。
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

    /// 从 original 生成重签名副本（新路径），返回副本 URL。
    /// 每次调用生成新 UUID 文件（全新 vnode = 全新校验）；同目录旧副本自动清理。
    static func rebuildToNewFile(at original: URL) throws -> URL {
        let PAGE = 4096
        let HASH = 32

        guard let fh = try? FileHandle(forReadingFrom: original) else { throw ReSignError.ioFailure("打开原文件失败") }
        defer { try? fh.close() }
        let head = try fh.readData(ofLength: 64 * 1024)
        func le32(_ o: Int, in d: Data) -> UInt32 { d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) } }
        guard le32(0, in: head) == 0xfeedfacf else { throw ReSignError.notMachO64 }
        let ncmds = Int(le32(16, in: head))

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
        let codeLimit = sigOff                       // 代码哈希覆盖 [0, 签名偏移)
        let nPages = Int((codeLimit + PAGE - 1) / PAGE)

        // 旧 identifier（保持模块身份稳定）
        var identifier = "openlist.dylib"
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
                        if end > start { identifier = String(bytes: blob[start..<end], encoding: .utf8) ?? identifier }
                    }
                    break
                }
            }
        }

        // 新签名布局（v0x20400 完整 88B 头）
        let hashOffset = 88
        let idLen = identifier.utf8.count + 1
        let cdIdentRel = hashOffset + nPages * HASH
        let cdLen = cdIdentRel + idLen
        let newSigSize = 12 + 8 + cdLen
        guard newSigSize <= sigSize else { throw ReSignError.ioFailure("新签名 \(newSigSize)B 超出原槽 \(sigSize)B") }

        // 新文件路径（全新 vnode）；清理旧副本防配额累积
        let dir = original.deletingLastPathComponent()
        if let olds = try? FileManager.default.contentsOfDirectory(at: dir) {
            for f in olds where f.lastPathComponent.contains("-rs-") { try? FileManager.default.removeItem(at: f) }
        }
        let uid = UUID().uuidString.prefix(8)
        let newURL = dir.appendingPathComponent(
            original.deletingPathExtension().lastPathComponent + "-rs-\(uid).dylib")

        // ---- 流式复制 + 补丁：datasize(LE) 改新长度；签名槽区清零 ----
        guard let src = try? FileHandle(forReadingFrom: original) else { throw ReSignError.ioFailure("打开原文件失败") }
        defer { try? src.close() }
        FileManager.default.createFile(atPath: newURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: newURL) else { throw ReSignError.ioFailure("创建新文件失败") }
        defer { try? out.close() }

        var copied: Int64 = 0
        var patchedDatasize = false
        src.seek(toFileOffset: 0)
        while copied < Int64(sigOff + sigSize) {
            let toRead = min(1024 * 1024, Int(sigOff + sigSize - copied))
            guard toRead > 0 else { break }
            let chunk = try src.readData(ofLength: toRead)
            guard chunk.count == toRead else { throw ReSignError.ioFailure("读块失败 @\(copied)") }
            var block = [UInt8](chunk)

            // datasize 字段（头部，LE）→ 新 blob 长度
            if !patchedDatasize, copied <= Int64(datasizeField), Int64(datasizeField) + 4 <= copied + Int64(block.count) {
                let rel = Int(Int64(datasizeField) - copied)
                let v = UInt32(newSigSize)
                block[rel] = UInt8(v & 0xff); block[rel + 1] = UInt8((v >> 8) & 0xff)
                block[rel + 2] = UInt8((v >> 16) & 0xff); block[rel + 3] = UInt8((v >> 24) & 0xff)
                patchedDatasize = true
            }
            // 签名槽区 → 清零（稍后写入新 blob）
            if copied + Int64(block.count) > Int64(sigOff) {
                let start = max(0, Int(Int64(sigOff) - copied))
                for i in start..<block.count { block[i] = 0 }
            }
            try? out.write(contentsOf: Data(block))
            copied += Int64(block.count)
        }
        try? out.synchronize()
        guard patchedDatasize else { throw ReSignError.ioFailure("datasize 字段未落在新文件头部") }

        // ---- 对新文件逐页哈希 → 构建 CodeDirectory/SuperBlob → 写回新文件签名槽 ----
        guard let rh = try? FileHandle(forReadingFrom: newURL) else { throw ReSignError.ioFailure("读新文件失败") }
        defer { try? rh.close() }
        rh.seek(toFileOffset: 0)
        var b = [UInt8]()
        func w32(_ v: Int) { b.append(UInt8((v >> 24) & 0xff)); b.append(UInt8((v >> 16) & 0xff)); b.append(UInt8((v >> 8) & 0xff)); b.append(UInt8(v & 0xff)) }
        // SuperBlob @0
        w32(0xfade0cc0)
        w32(0)                    // length 占位
        w32(1)                    // count
        // index[0] @12
        w32(0)                    // CSSLOT_CODEDIRECTORY
        w32(20)                   // CD @20
        // CodeDirectory @20 —— v0x20400 完整 88B 头
        w32(0xfade0c02)
        w32(0)                    // length 占位
        w32(0x20400)              // version
        w32(0x2)                  // flags = CS_ADHOC（无 CMS，纯哈希校验必须带）
        w32(hashOffset)           // hashOffset（相对 cd）
        w32(hashOffset + nPages * HASH)  // identOffset（相对 cd）
        w32(0)                    // nSpecialSlots
        w32(nPages)               // nCodeSlots
        w32(codeLimit)            // codeLimit
        b.append(32)              // hashSize = SHA256
        b.append(2)               // hashType = SHA256
        b.append(0)               // platform
        b.append(12)              // pageSize log2（4096）
        w32(0)                    // spare2
        w32(0)                    // scatterOffset
        w32(0)                    // teamOffset
        w32(0)                    // spare3
        w32(Int(codeLimit >> 32)) // codeLimit64 hi
        w32(codeLimit & 0xffffffff) // codeLimit64 lo
        w32(0); w32(0)            // execSegBase
        w32(0); w32(0)            // execSegLimit（dylib=0）
        w32(0); w32(0)            // execSegFlags
        while b.count < 20 + hashOffset { b.append(0) }
        // 页哈希（读新文件：datasize 已是新值，第 0 页哈希才正确）
        for _ in 0..<nPages {
            let remaining = codeLimit - Int(rh.offsetInFile)
            guard remaining > 0 else { break }
            let toRead = min(PAGE, remaining)
            let chunk = try rh.readData(ofLength: toRead)
            guard chunk.count == toRead else { throw ReSignError.ioFailure("读页失败 @\(rh.offsetInFile)") }
            b.append(contentsOf: SHA256.hash(data: chunk))
        }
        b.append(contentsOf: Array(identifier.utf8))
        b.append(0)

        func p32(_ at: Int, _ v: Int) { b[at] = UInt8((v >> 24) & 0xff); b[at+1] = UInt8((v >> 16) & 0xff); b[at+2] = UInt8((v >> 8) & 0xff); b[at+3] = UInt8(v & 0xff) }
        p32(4, b.count)
        p32(24, cdLen)
        p32(40, cdIdentRel)
        guard b.count == newSigSize else { throw ReSignError.ioFailure("blob 尺寸 \(b.count) ≠ 预期 \(newSigSize)") }

        // 写入新文件的签名槽（全新 vnode，无缓存判决污染）
        out.seek(toFileOffset: UInt64(sigOff))
        try? out.write(contentsOf: Data(b))
        try? out.synchronize()
        return newURL
    }
}
