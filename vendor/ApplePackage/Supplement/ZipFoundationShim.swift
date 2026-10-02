import Foundation

// MARK: - ZIPFoundation 兼容层（EscapeSpace / Theos 适配）
//
// ApplePackage 用 ZIPFoundation 往下载的 IPA 里注入 sinf（App Store 的
// FairPlay 签名数据，缺它 IPA 装不上）。Theos 不能引 SwiftPM，所以这里用
// 项目已有的 **SWCompression**（Deflate 压缩/解压）+ 一段精简的 ZIP 写入
// 逻辑替代，保持调用点 API 形状不变：
// - `ApplePackageArchive(url:accessMode:)` / `.update` / `.read`
// - 遍历 `for entry in archive`、`archive[path]`
// - `archive.extract(entry, consumer:)`
// - `archive.addEntry(with:type:uncompressedSize:compressionMethod:provider:)`

public struct ZipEntryRef {
    public let path: String
    /// 该条目 local header 在文件中的偏移。
    public let localHeaderOffset: UInt32
    public let compressedSize: UInt32
    public let uncompressedSize: UInt32
    public let crc32: UInt32
    /// 0 = 存储，8 = deflate
    public let compressionMethod: UInt16
    /// 中央目录里的原始描述（用于重写中央目录时原样保留）。
    let centralDirRecord: Data
}

public enum ZipAccessMode { case read, update, create }

public enum ApplePackageZipError: Error, LocalizedError {
    case cannotOpen(String)
    case malformed(String)
    case entryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let p): return "无法打开 ZIP：\(p)"
        case .malformed(let m): return "ZIP 结构异常：\(m)"
        case .entryNotFound(let p): return "ZIP 中找不到条目：\(p)"
        }
    }
}

/// 极简 ZIP 读写器：读（遍历 / 解压）+ 追加条目（deflate）。
public final class ApplePackageArchive {

    public let url: URL
    private let fileHandle: FileHandle
    /// `replaceEntry` 整包重写后置位 —— 之后的 `deinit` 不再尝试落盘。
    private var didRewrite = false
    private(set) public var entries: [ZipEntryRef] = []
    /// 中央目录在文件中的起始偏移（追加新条目时从这里截断）。
    private var centralDirOffset: UInt64 = 0
    private var pendingAdds: [(path: String, data: Data, method: ZipCompressionMethod)] = []

    public init(url: URL, accessMode: ZipAccessMode) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ApplePackageZipError.cannotOpen(url.path)
        }
        let handle = try FileHandle(forUpdating: url)
        self.fileHandle = handle
        try parseCentralDirectory()
    }

    deinit {
        if !didRewrite {
            do {
                try flushPendingAdds()
            } catch {
                // 追加失败不抛（deinit 不能抛）
            }
        }
        try? fileHandle.close()
    }

    // MARK: - 读取

    /// 解压并读取某个条目的内容。
    public func extract(_ entry: ZipEntryRef, consumer: (Data) -> Void) throws {
        fileHandle.seek(toFileOffset: UInt64(entry.localHeaderOffset))
        let header = fileHandle.readData(ofLength: 30)
        guard header.count == 30 else { throw ApplePackageZipError.malformed("local header 过短") }
        let nameLength = header.uint16(at: 26)
        let extraLength = header.uint16(at: 28)
        fileHandle.seek(toFileOffset: UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLength) + UInt64(extraLength))
        var compressed = fileHandle.readData(ofLength: Int(entry.compressedSize))
        guard compressed.count == Int(entry.compressedSize) else {
            throw ApplePackageZipError.malformed("条目数据不完整：\(entry.path)")
        }
        if entry.compressionMethod == 8 {
            compressed = try Deflate.decompress(data: compressed)
        }
        consumer(compressed)
    }

    public subscript(path: String) -> ZipEntryRef? {
        entries.first { $0.path == path }
    }

    // MARK: - 删除（仅从中央目录摘除）

    /// 把某个条目从**中央目录**里摘掉（v0.3.546 新增）。
    ///
    /// ## 为什么不是真的从文件里删掉字节
    ///
    /// ZIP 的权威索引是中央目录 —— 条目的数据块留在文件里但**不被中央目录引用**时，
    /// 解压器一律看不到它。真正的字节级删除要把后面所有内容前移、并重算所有
    /// `localHeaderOffset`，在流式读写的场景下又慢又容易写坏（一次 200MB 的 IPA 要搬一遍）。
    ///
    /// 只摘中央目录的代价是文件不再缩小（垃圾字节留在原处），
    /// 但**语义上是干净的替换**：同名条目在中央目录里只会出现一次，
    /// 解压结果以新的为准。这对我们完全够用 —— `PackageSINFWriter` 要的
    /// 就是「把包内那份不属于本机的 sinf 换成服务端下发的这一份」。
    ///
    /// ## 调用顺序约束
    ///
    /// 必须**在 `addEntry` 之前**调用。若先 `addEntry` 再删，删的会是旧条目、
    /// 而新条目已经挂进 `pendingAdds` —— 结果两个都进中央目录（重名），比不删更糟。
    ///
    /// ## ★★ v0.3.558：本方法是**纯内存操作**，删完必须自己落盘
    ///
    /// 它只改 `entries` 数组，不碰文件。而 `flush()` 在 `pendingAdds` 为空时是 no-op，
    /// 所以「`removeEntry` + 之后某次 `flush()`」这个组合**不会让删除生效**：
    /// 那次 flush 重新拼中央目录时，`entries` 里旧记录还在（除非删的时候正好也有 pending）
    /// → 中央目录里出现**同名两条** → 苹果解压器报
    /// `PackageExtractionFailed (Could not extract archive)`（真机 0.4 秒内失败）。
    ///
    /// 正确用法（见 `PackageSINFWriter`）：
    /// ```
    /// archive.removeEntry(with: path)
    /// try archive.flushCentralDirectory()   // 让「删」真正落盘
    /// try archive.addEntry(with: path, …)
    /// try archive.flush()
    /// ```
    public func removeEntry(with path: String) {
        entries.removeAll { $0.path == path }
    }

    // MARK: - 整包重写替换（v0.3.560）

    /// 把 `path` 换成新数据：**逐条把原包复制成一份新包**，替换的那条写新内容。
    ///
    /// ## 为什么必须整包重写（真机实证）
    ///
    /// 之前用的是「摘中央目录记录 + 在旧中央目录起点追加新条目」的原地改法。
    /// 真机上（0.3.546 → 0.3.559）加密包**一直**报
    /// `PackageExtractionFailed (Could not extract archive)`。
    ///
    /// 原地改法在 ZIP 层会被留下两个痕迹，苹果的解压通道不吃：
    /// 1. **旧 sinf 那条的 local header + 数据块还在文件里**（只摘了索引），
    ///    文件里多出一个**没有任何中央目录记录指向的 `PK\x03\x04`**；
    /// 2. 新条目的属性是我们自己拼的（`version made by = 20`、无 extra），
    ///    与苹果自己的条目（`0x314` = Unix + 2.0，带 extra）不同源。
    ///
    /// 整包重写后产物与「苹果自己压的包」同构：条目顺序、属性、偏移全部连续，
    /// 没有孤儿字节，没有自拼的属性差异。
    ///
    /// 代价是要把整包复制一遍（3.5MB ~ 500MB 按字节顺序 copy，无解压/重压缩），
    /// 换取的是**产物结构必然合法**。
    ///
    /// - Parameters:
    ///   - path: 要替换的条目路径（不存在时按追加处理）。
    ///   - data: 新数据（存储方式写入，method=0）。
    public func replaceEntry(with path: String, data: Data) throws {
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).rewrite-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        guard let out = FileHandle(forWritingTo: tmpURL) else {
            throw ApplePackageZipError.cannotOpen(tmpURL.path)
        }

        // 源文件整体映射读（不整块载入内存）
        let src = try Data(contentsOf: url, options: .mappedIfSafe)

        var newCentral = Data()
        var offset: UInt64 = 0
        var replaced = false

        for entry in entries {
            if entry.path == path {
                // 命中：写入新数据的 local header + 数据
                let nameData = Data(path.utf8)
                let crc = CRC32.data(data)
                var local = Data()
                local.append(uint32Le(0x04034B50))
                local.append(uint16Le(20))          // version needed
                local.append(uint16Le(0))           // flags
                local.append(uint16Le(0))           // method = 存储
                local.append(uint16Le(0))           // mod time
                local.append(uint16Le(0))           // mod date
                local.append(uint32Le(crc))
                local.append(uint32Le(UInt32(data.count)))
                local.append(uint32Le(UInt32(data.count)))
                local.append(uint16Le(UInt16(nameData.count)))
                local.append(uint16Le(0))           // extra length
                local.append(nameData)
                local.append(data)
                out.write(local)

                var central = Data()
                central.append(uint32Le(0x02014B50))
                // 与苹果条目同源：version made by = 0x314（Unix + 2.0）
                central.append(uint16Le(0x0314))
                central.append(uint16Le(20))
                central.append(uint16Le(0))         // flags
                central.append(uint16Le(0))         // method = 存储
                central.append(uint16Le(0))         // time
                central.append(uint16Le(0))         // date
                central.append(uint32Le(crc))
                central.append(uint32Le(UInt32(data.count)))
                central.append(uint32Le(UInt32(data.count)))
                central.append(uint16Le(UInt16(nameData.count)))
                central.append(uint16Le(0))         // extra
                central.append(uint16Le(0))         // comment
                central.append(uint16Le(0))         // disk
                central.append(uint16Le(0))         // internal attrs
                central.append(uint32Le(0))         // external attrs
                central.append(uint32Le(UInt32(offset)))
                central.append(nameData)
                newCentral.append(central)

                offset += UInt64(local.count)
                replaced = true
                continue
            }

            // 其余条目：原样搬运 local header + 数据
            let start = Int(entry.localHeaderOffset)
            let header = src.subdata(in: start ..< (start + 30))
            guard header.count == 30, header.uint32(at: 0) == 0x04034B50 else {
                try? FileManager.default.removeItem(at: tmpURL)
                throw ApplePackageZipError.malformed("local header 异常：\(entry.path)")
            }
            let nameLen = Int(header.uint16(at: 26))
            let extraLen = Int(header.uint16(at: 28))
            let payloadStart = start + 30 + nameLen + extraLen
            // 该条目的物理占用：local header + 数据（用中央目录里的压缩后长度）
            let payloadLen = Int(entry.compressedSize)
            let payload = src.subdata(in: payloadStart ..< (payloadStart + payloadLen))
            guard payload.count == payloadLen else {
                try? FileManager.default.removeItem(at: tmpURL)
                throw ApplePackageZipError.malformed("条目数据不完整：\(entry.path)")
            }

            out.write(header)
            out.write(src.subdata(in: (start + 30) ..< payloadStart))   // name + extra
            out.write(payload)

            // 中央目录记录：拷原记录，只把 localHeaderOffset 改成新偏移
            var central = entry.centralDirRecord
            central.replaceSubrange(42 ..< 46, with: uint32Le(UInt32(offset)))
            newCentral.append(central)

            offset += UInt64(30 + nameLen + extraLen + payloadLen)
        }

        if !replaced {
            // 原包没有这条 → 追加
            let nameData = Data(path.utf8)
            let crc = CRC32.data(data)
            var local = Data()
            local.append(uint32Le(0x04034B50))
            local.append(uint16Le(20))
            local.append(uint16Le(0))
            local.append(uint16Le(0))
            local.append(uint16Le(0))
            local.append(uint16Le(0))
            local.append(uint32Le(crc))
            local.append(uint32Le(UInt32(data.count)))
            local.append(uint32Le(UInt32(data.count)))
            local.append(uint16Le(UInt16(nameData.count)))
            local.append(uint16Le(0))
            local.append(nameData)
            local.append(data)
            out.write(local)

            var central = Data()
            central.append(uint32Le(0x02014B50))
            central.append(uint16Le(0x0314))
            central.append(uint16Le(20))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint32Le(crc))
            central.append(uint32Le(UInt32(data.count)))
            central.append(uint32Le(UInt32(data.count)))
            central.append(uint16Le(UInt16(nameData.count)))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint16Le(0))
            central.append(uint32Le(0))
            central.append(uint32Le(UInt32(offset)))
            central.append(nameData)
            newCentral.append(central)
            offset += UInt64(local.count)
        }

        // 中央目录 + EOCD
        out.write(newCentral)
        let total = entries.count + (replaced ? 0 : 1)
        guard total <= Int(UInt16.max) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ApplePackageZipError.malformed("条目数超出 ZIP 上限")
        }
        out.write(eocdData(entryCount: UInt16(total),
                           centralSize: UInt32(newCentral.count),
                           centralOffset: UInt32(offset)))
        try out.synchronize()
        try out.close()

        // 原子替换（先把原句柄关掉，再换文件）
        try? fileHandle.close()
        didRewrite = true
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            // 回退：删原文件再移动（`replaceItemAt` 在某些沙盒属性下会失败）
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    // MARK: - 追加

    /// 追加一个条目。真正的写入在 `flush()` 时统一完成。
    ///
    /// ★ v0.3.550：**支持 `compressionMethod: .none`（存储）**。
    ///
    /// 之前这里只有一条 deflate 路，写死 `method = 8` —— 但我们这个压缩器
    /// 是 SWCompression 里那个**自陈为 "a band-aid solution"** 的静态 Huffman 实现
    /// （`Deflate+Compress.swift` 注释原话），只生成**单个** block，超过 65535 字节
    /// 还会退化。sinf 这种小文件完全没必要冒这个险：**存储方式（method=0）**
    /// 在 ZIP 里是合法的，任何解压器都认，而且省掉一次编码。
    ///
    /// 需要压缩的调用点（如注入大文件）仍可传 `.deflate`，行为不变。
    public func addEntry(
        with path: String,
        type: ZipEntryType = .file,
        uncompressedSize: Int64,
        compressionMethod: ZipCompressionMethod = .deflate,
        provider: (Int64, Int) -> Data
    ) throws {
        var data = Data()
        var position: Int64 = 0
        let total = Int(uncompressedSize)
        while position < total {
            let size = Swift.min(1 << 20, total - Int(position))
            data.append(provider(position, size))
            position += Int64(size)
        }
        pendingAdds.append((path: path, data: data, method: compressionMethod))
    }

    public enum ZipEntryType { case file, directory, symlink }
    public enum ZipCompressionMethod { case none, deflate }

    /// 把待追加条目写入文件，并重写中央目录。
    ///
    /// ⚠️ `pendingAdds` 为空时本方法**直接 return、什么都不做** ——
    /// 所以它**不能**用来「把 removeEntry 的效果落盘」。
    /// 摘条目之后必须走 `flushCentralDirectory()`（v0.3.558 新增）。
    public func flush() throws {
        try flushPendingAdds()
    }

    /// 只重写中央目录 + EOCD（不动条目数据）。
    ///
    /// ★ v0.3.558：给 `removeEntry(with:)` 配的落盘口。
    ///
    /// `removeEntry` 只改内存 `entries`，而 `flush()` 在 `pendingAdds` 为空时是 no-op，
    /// 于是「删」根本没有落到文件上 → 下次 `flush()` 重新拼中央目录时
    /// **旧记录被原样带上**，与新增的同名条目一起写进中央目录（**重名**）。
    /// 真机表现就是 0.4~1.2 秒内 `PackageExtractionFailed (Could not extract archive)`。
    ///
    /// 本方法在「旧中央目录起点」原地重写一份**合法**的中央目录 + EOCD：
    /// 条目数、总长、偏移全部按当前 `entries` 重算，尾部截断到新 EOCD 末尾。
    /// 中间态永远是**结构完整**的 ZIP，所以即便后续 add 失败，包也不会被写坏。
    public func flushCentralDirectory() throws {
        fileHandle.seek(toFileOffset: centralDirOffset)

        var allCentral = Data()
        for entry in entries { allCentral.append(entry.centralDirRecord) }

        fileHandle.write(allCentral)
        fileHandle.write(eocdData(entryCount: UInt16(entries.count),
                                  centralSize: UInt32(allCentral.count),
                                  centralOffset: UInt32(centralDirOffset)))
        try fileHandle.truncate(atOffset: fileHandle.offsetInFile)
        try fileHandle.synchronize()
    }

    /// 拼一份 EOCD（22 字节，无注释）。
    private func eocdData(entryCount: UInt16, centralSize: UInt32, centralOffset: UInt32) -> Data {
        var eocd = Data()
        eocd.append(uint32Le(0x06054B50))
        eocd.append(uint16Le(0))            // disk number
        eocd.append(uint16Le(0))            // disk with cd
        eocd.append(uint16Le(entryCount))
        eocd.append(uint16Le(entryCount))
        eocd.append(uint32Le(centralSize))
        eocd.append(uint32Le(centralOffset))
        eocd.append(uint16Le(0))            // comment length
        return eocd
    }

    private func flushPendingAdds() throws {
        guard !pendingAdds.isEmpty else { return }
        let adds = pendingAdds
        pendingAdds.removeAll()

        // 1) 截掉原中央目录 + EOCD，定位追加起点
        fileHandle.seek(toFileOffset: centralDirOffset)
        var output = Data()
        var newEntries: [ZipEntryRef] = []

        for add in adds {
            let nameData = Data(add.path.utf8)
            let crc = CRC32.data(add.data)
            // v0.3.550：按调用方指定的方式写（`.none` = 存储，method 0；`.deflate` = 8）。
            let useDeflate = (add.method == .deflate)
            let payload = useDeflate ? Deflate.compress(data: add.data) : add.data
            let methodCode: UInt16 = useDeflate ? 8 : 0
            let localOffset = UInt64(centralDirOffset) + UInt64(output.count)

            var local = Data()
            local.append(uint32Le(0x04034B50))
            local.append(uint16Le(20))          // version needed
            local.append(uint16Le(0))           // flags
            local.append(uint16Le(methodCode))  // method
            local.append(uint16Le(0))           // mod time
            local.append(uint16Le(0))           // mod date
            local.append(uint32Le(crc))
            local.append(uint32Le(UInt32(payload.count)))
            local.append(uint32Le(UInt32(add.data.count)))
            local.append(uint16Le(UInt16(nameData.count)))
            local.append(uint16Le(0))           // extra length
            local.append(nameData)
            local.append(payload)
            output.append(local)

            // 中央目录记录
            var central = Data()
            central.append(uint32Le(0x02014B50))
            central.append(uint16Le(20))        // version made by
            central.append(uint16Le(20))        // version needed
            central.append(uint16Le(0))         // flags
            central.append(uint16Le(methodCode))// method
            central.append(uint16Le(0))         // time
            central.append(uint16Le(0))         // date
            central.append(uint32Le(crc))
            central.append(uint32Le(UInt32(payload.count)))
            central.append(uint32Le(UInt32(add.data.count)))
            central.append(uint16Le(UInt16(nameData.count)))
            central.append(uint16Le(0))         // extra
            central.append(uint16Le(0))         // comment
            central.append(uint16Le(0))         // disk number
            central.append(uint16Le(0))         // internal attrs
            central.append(uint32Le(0))         // external attrs
            central.append(uint32Le(UInt32(localOffset)))
            central.append(nameData)
            newEntries.append(ZipEntryRef(path: add.path,
                                          localHeaderOffset: UInt32(localOffset),
                                          compressedSize: UInt32(payload.count),
                                          uncompressedSize: UInt32(add.data.count),
                                          crc32: crc,
                                          compressionMethod: methodCode,
                                          centralDirRecord: central))
        }

        // 2) 写入：新条目数据 + 旧中央目录 + 新条目中央目录 + EOCD
        fileHandle.seek(toFileOffset: centralDirOffset)
        fileHandle.write(output)
        var allCentral = Data()
        for entry in entries { allCentral.append(entry.centralDirRecord) }
        for entry in newEntries { allCentral.append(entry.centralDirRecord) }
        fileHandle.write(allCentral)

        fileHandle.write(eocdData(entryCount: UInt16(entries.count + newEntries.count),
                                  centralSize: UInt32(allCentral.count),
                                  centralOffset: UInt32(centralDirOffset + UInt64(output.count))))

        // ★ v0.3.550：**必须截断**，否则包会被写坏（真机实证）。
        //
        // 我们是从**旧中央目录的起点**开始覆写的：
        //     centralDirOffset ─┬─ 旧中央目录 ─┬─ 旧 EOCD
        //                       └─ 新条目 + 新中央目录 + 新 EOCD（长度通常与旧的不同）
        //
        // 若新写的总长 **比旧的短**（删掉一个条目又只加一个更小的，就可能短），
        // 文件尾部会残留**旧 EOCD 的一部分字节**。解压器找 EOCD 是**从文件末尾往回扫**，
        // 于是先撞上那个残留的假 EOCD —— 它指向的中央目录区已经被新内容覆盖，
        // 结构对不上 → 解压直接失败。
        //
        // 真机上的表现（2026-10-02 日志）：
        //   [下载中心] 安装失败 ChatGPT-x.ipa：
        //     UnknownErrorType("PackageExtractionFailed (Could not extract archive)")
        // 就是这条 —— 下载好的 IPA 在写入 sinf 之后解不开了。
        //
        // `truncate(atOffset:)` 按当前句柄位置截断，正好落在新 EOCD 的末尾。
        try fileHandle.truncate(atOffset: fileHandle.offsetInFile)
        try fileHandle.synchronize()

        entries.append(contentsOf: newEntries)
        centralDirOffset = centralDirOffset + UInt64(output.count)
    }

    // MARK: - 解析中央目录

    private func parseCentralDirectory() throws {
        let fileSize = try FileHandle(forReadingFrom: url).seekToEndOfFile()
        // 读尾部 64KB 定位 EOCD
        let tailLength = Swift.min(UInt64(1 << 16), fileSize)
        fileHandle.seek(toFileOffset: fileSize - tailLength)
        let tail = fileHandle.readData(ofLength: Int(tailLength))
        guard let eocdRange = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: Data.SearchOptions.backwards) else {
            throw ApplePackageZipError.malformed("未找到 EOCD")
        }
        let eocdOffset = fileSize - tailLength + UInt64(eocdRange.lowerBound)
        let eocd = tail.subdata(in: eocdRange.lowerBound ..< Swift.min(eocdRange.lowerBound + 22, tail.count))
        guard eocd.count >= 22 else { throw ApplePackageZipError.malformed("EOCD 过短") }
        let cdSize = eocd.uint32(at: 12)
        let cdOffset = eocd.uint32(at: 16)
        centralDirOffset = UInt64(cdOffset)

        fileHandle.seek(toFileOffset: UInt64(cdOffset))
        let centralData = fileHandle.readData(ofLength: Int(cdSize))
        guard centralData.count == Int(cdSize) else { throw ApplePackageZipError.malformed("中央目录读取不完整") }

        var position = 0
        while position + 46 <= centralData.count {
            guard centralData.uint32(at: position) == 0x02014B50 else { break }
            let method = centralData.uint16(at: position + 10)
            let crc = centralData.uint32(at: position + 16)
            let compressedSize = centralData.uint32(at: position + 20)
            let uncompressedSize = centralData.uint32(at: position + 24)
            let nameLength = Int(centralData.uint16(at: position + 28))
            let extraLength = Int(centralData.uint16(at: position + 30))
            let commentLength = Int(centralData.uint16(at: position + 32))
            let localOffset = centralData.uint32(at: position + 42)
            let nameStart = position + 46
            guard nameStart + nameLength <= centralData.count else { break }
            let nameData = centralData.subdata(in: nameStart ..< (nameStart + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else { break }
            let recordLength = 46 + nameLength + extraLength + commentLength
            entries.append(ZipEntryRef(path: name,
                                       localHeaderOffset: localOffset,
                                       compressedSize: compressedSize,
                                       uncompressedSize: uncompressedSize,
                                       crc32: crc,
                                       compressionMethod: method,
                                       centralDirRecord: centralData.subdata(in: position ..< (position + recordLength))))
            position += recordLength
        }
    }
}

// MARK: Sequence

extension ApplePackageArchive: Sequence {
    public func makeIterator() -> IndexingIterator<[ZipEntryRef]> {
        entries.makeIterator()
    }
}

// MARK: - 小工具

private func uint16Le(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
}

private func uint32Le(_ value: UInt32) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
          UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

/// CRC32（zlib 多项式），ZIP 条目需要。
private enum CRC32 {
    static func data(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
