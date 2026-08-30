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
    private(set) public var entries: [ZipEntryRef] = []
    /// 中央目录在文件中的起始偏移（追加新条目时从这里截断）。
    private var centralDirOffset: UInt64 = 0
    private var pendingAdds: [(path: String, data: Data)] = []

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
        do {
            try flushPendingAdds()
        } catch {
            // 追加失败不抛（deinit 不能抛）
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

    // MARK: - 追加

    /// 追加一个条目（deflate 压缩）。真正的写入在 `flush()` 时统一完成。
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
            let size = min(1 << 20, total - Int(position))
            data.append(provider(position, size))
            position += Int64(size)
        }
        pendingAdds.append((path: path, data: data))
    }

    public enum ZipEntryType { case file, directory, symlink }
    public enum ZipCompressionMethod { case none, deflate }

    /// 把待追加条目写入文件，并重写中央目录。
    public func flush() throws {
        try flushPendingAdds()
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
            let compressed = Deflate.compress(data: add.data)
            let localOffset = UInt64(centralDirOffset) + UInt64(output.count)

            var local = Data()
            local.append(uint32Le(0x04034B50))
            local.append(uint16Le(20))          // version needed
            local.append(uint16Le(0))           // flags
            local.append(uint16Le(8))           // method: deflate
            local.append(uint16Le(0))           // mod time
            local.append(uint16Le(0))           // mod date
            local.append(uint32Le(crc))
            local.append(uint32Le(UInt32(compressed.count)))
            local.append(uint32Le(UInt32(add.data.count)))
            local.append(uint16Le(UInt16(nameData.count)))
            local.append(uint16Le(0))           // extra length
            local.append(nameData)
            local.append(compressed)
            output.append(local)

            // 中央目录记录
            var central = Data()
            central.append(uint32Le(0x02014B50))
            central.append(uint16Le(20))        // version made by
            central.append(uint16Le(20))        // version needed
            central.append(uint16Le(0))         // flags
            central.append(uint16Le(8))         // method
            central.append(uint16Le(0))         // time
            central.append(uint16Le(0))         // date
            central.append(uint32Le(crc))
            central.append(uint32Le(UInt32(compressed.count)))
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
                                          compressedSize: UInt32(compressed.count),
                                          uncompressedSize: UInt32(add.data.count),
                                          crc32: crc,
                                          compressionMethod: 8,
                                          centralDirRecord: central))
        }

        // 2) 写入：新条目数据 + 旧中央目录 + 新条目中央目录 + EOCD
        fileHandle.seek(toFileOffset: centralDirOffset)
        fileHandle.write(output)
        var allCentral = Data()
        for entry in entries { allCentral.append(entry.centralDirRecord) }
        for entry in newEntries { allCentral.append(entry.centralDirRecord) }
        fileHandle.write(allCentral)

        var eocd = Data()
        eocd.append(uint32Le(0x06054B50))
        eocd.append(uint16Le(0))            // disk number
        eocd.append(uint16Le(0))            // disk with cd
        eocd.append(uint16Le(UInt16(entries.count + newEntries.count)))
        eocd.append(uint16Le(UInt16(entries.count + newEntries.count)))
        eocd.append(uint32Le(UInt32(allCentral.count)))
        eocd.append(uint32Le(UInt32(centralDirOffset + UInt64(output.count))))
        eocd.append(uint16Le(0))            // comment length
        fileHandle.write(eocd)
        try fileHandle.synchronize()

        entries.append(contentsOf: newEntries)
        centralDirOffset = centralDirOffset + UInt64(output.count)
    }

    // MARK: - 解析中央目录

    private func parseCentralDirectory() throws {
        let fileSize = try FileHandle(forReadingFrom: url).seekToEndOfFile()
        // 读尾部 64KB 定位 EOCD
        let tailLength = min(UInt64(1 << 16), fileSize)
        fileHandle.seek(toFileOffset: fileSize - tailLength)
        let tail = fileHandle.readData(ofLength: Int(tailLength))
        guard let eocdRange = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards) else {
            throw ApplePackageZipError.malformed("未找到 EOCD")
        }
        let eocdOffset = fileSize - tailLength + UInt64(eocdRange.lowerBound)
        let eocd = tail.subdata(in: eocdRange.lowerBound ..< min(eocdRange.lowerBound + 22, tail.count))
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
