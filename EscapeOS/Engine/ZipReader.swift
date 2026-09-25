import Foundation
import zlib

/// A single entry inside a ZIP archive.
struct ZipMember {
    let name: String
    let compressedSize: Int
    let uncompressedSize: Int
    let crc32: UInt32
    let localHeaderOffset: Int
    let compression: Int
    let flags: UInt16
    let dosTime: UInt16
    let aes: ZipAESInfo?

    var isEncrypted: Bool { flags & 0x1 != 0 || compression == 99 || aes != nil }
    var usesDataDescriptor: Bool { flags & 0x8 != 0 }
}

/// Errors when reading ZIP archives.
enum ZipReaderError: Error, LocalizedError {
    case invalidArchive(String)
    case entryNotFound(String)
    case checksumMismatch(String)
    case unsupportedCompression(String)
    case passwordRequired
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let m): return "Invalid zip: \(m)"
        case .entryNotFound(let n): return "Missing file in archive: \(n)"
        case .checksumMismatch(let n): return "Checksum failed for \(n)"
        case .unsupportedCompression(let n): return "Unsupported compression for \(n)"
        case .passwordRequired: return "This archive is password-protected."
        case .wrongPassword: return "Wrong archive password."
        }
    }
}

/// Random-access byte source behind a `ZipReader`.
///
/// Two implementations exist: an in-memory blob (for callers that already hold
/// the archive as `Data`) and an on-disk file handle. The file-backed source is
/// what keeps a large backup readable: the reader only ever touches the end of
/// central directory plus the bytes of the entries it actually needs, instead
/// of loading the whole archive into RAM.
protocol ZipByteSource: AnyObject {
    /// Total number of bytes in the archive.
    var size: Int { get }
    /// Read exactly `length` bytes starting at `offset`.
    func read(at offset: Int, length: Int) throws -> Data
    /// Release the underlying resource. Safe to call more than once.
    func close()
}

/// In-memory archive source.
final class ZipDataByteSource: ZipByteSource {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    var size: Int { data.count }

    func read(at offset: Int, length: Int) throws -> Data {
        guard length >= 0, offset >= 0, offset + length <= data.count else {
            throw ZipReaderError.invalidArchive("Read out of range")
        }
        return data.subdata(in: offset..<(offset + length))
    }

    func close() {}
}

/// File-backed archive source using `FileHandle` seek + read.
final class ZipFileByteSource: ZipByteSource {
    private let handle: FileHandle
    let size: Int

    init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        self.handle = try FileHandle(forReadingFrom: url)
    }

    func read(at offset: Int, length: Int) throws -> Data {
        guard length >= 0, offset >= 0, offset + length <= size else {
            throw ZipReaderError.invalidArchive("Read out of range")
        }
        guard length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        var remaining = length
        var buffer = Data()
        buffer.reserveCapacity(length)
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw ZipReaderError.invalidArchive("Truncated archive")
            }
            buffer.append(chunk)
            remaining -= chunk.count
        }
        return buffer
    }

    func close() {
        try? handle.close()
    }

    deinit {
        try? handle.close()
    }
}

/// ZIP reader for store (method 0) and deflate (method 8). Used by backup
/// restore and Extract. Supports ZIP64 sizes / offsets and, for file-backed
/// archives, never loads the whole archive into memory.
final class ZipReader {

    private let source: ZipByteSource
    private(set) var entries: [String: ZipMember] = [:]

    init(url: URL) throws {
        self.source = try ZipFileByteSource(url: url)
        try parseCentralDirectory()
    }

    init(data: Data) throws {
        self.source = ZipDataByteSource(data: data)
        try parseCentralDirectory()
    }

    /// Release the underlying file handle. No-op for in-memory archives.
    func close() {
        source.close()
    }

    func entryNames() -> [String] {
        entries.keys.sorted()
    }

    var needsPassword: Bool {
        entries.values.contains(where: \.isEncrypted)
    }

    func readEntry(named name: String, password: String? = nil) throws -> Data {
        guard let entry = entries[name] else {
            throw ZipReaderError.entryNotFound(name)
        }
        return try readEntry(entry, password: password)
    }

    func readEntry(_ entry: ZipMember, password: String? = nil) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard localOffset >= 0, localOffset + 30 <= source.size else {
            throw ZipReaderError.invalidArchive("Truncated local header for \(entry.name)")
        }

        let sig = try source.readUInt32(at: localOffset)
        guard sig == 0x04034b50 else {
            throw ZipReaderError.invalidArchive("Bad local header for \(entry.name)")
        }

        let compression = Int(try source.readUInt16(at: localOffset + 8))
        let nameLen = Int(try source.readUInt16(at: localOffset + 26))
        let extraLen = Int(try source.readUInt16(at: localOffset + 28))
        let payloadStart = localOffset + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= source.size else {
            throw ZipReaderError.invalidArchive("Truncated payload for \(entry.name)")
        }

        let stored = try source.read(at: payloadStart, length: entry.compressedSize)
        var working = stored
        var method = compression
        if entry.isEncrypted {
            guard let password, !password.isEmpty else {
                throw ZipReaderError.passwordRequired
            }
            if let aes = entry.aes {
                working = try ZipPassword.decryptAES(ciphertext: stored, password: password, aes: aes)
                method = aes.compression
            } else if compression == 99 {
                throw ZipReaderError.invalidArchive("AES extra field missing for \(entry.name)")
            } else {
                working = try ZipPassword.decryptZipCrypto(
                    ciphertext: stored,
                    password: password,
                    crc32: entry.crc32,
                    dosTime: entry.dosTime,
                    usesDataDescriptor: entry.usesDataDescriptor
                )
            }
        }

        let payload: Data
        switch method {
        case 0:
            payload = working
        case 8:
            payload = try Self.inflateRaw(working, expected: entry.uncompressedSize)
        default:
            throw ZipReaderError.unsupportedCompression(entry.name)
        }

        if entry.crc32 != 0 {
            var crc: uLong = crc32(0, nil, 0)
            payload.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(payload.count))
                }
            }
            guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else {
                throw ZipReaderError.checksumMismatch(entry.name)
            }
        }
        if entry.uncompressedSize > 0, payload.count != entry.uncompressedSize {
            throw ZipReaderError.invalidArchive("Size mismatch for \(entry.name)")
        }
        return payload
    }

    /// Stream one entry to `sink` in `chunkSize`-byte pieces instead of
    /// returning the whole payload as `Data`.
    ///
    /// This is what makes restoring a *single* multi-gigabyte file possible:
    /// `readEntry` would materialise the whole 4 GiB+ entry in memory and get
    /// the process jetsam-killed, while this method touches at most one chunk
    /// at a time through the same `ZipByteSource` the reader already uses.
    ///
    /// Only plain *stored* entries (compression method 0, no encryption) take
    /// the streaming path - and that is exactly what a backup archive contains,
    /// because `ZipWriter` is store-only. Any other entry (deflate, AES,
    /// ZipCrypto) is decoded whole through `readEntry` and handed to `sink` in
    /// a single call, so those flavours keep the exact same decoding and
    /// validation as before instead of getting a second implementation.
    ///
    /// Returns the number of uncompressed bytes written to `sink`.
    ///
    /// Validation is *not* weakened by streaming: the stored bytes are CRC32
    /// checked incrementally against the central directory, and the byte count
    /// is checked against the declared uncompressed size, mirroring `readEntry`.
    /// Note that an error (a failed CRC, a truncated archive, a `sink` failure
    /// such as a full disk) can therefore be thrown *after* `sink` has already
    /// received a prefix of the data. Callers that write to disk must stream
    /// into a temporary file and only publish it once this method returns.
    @discardableResult
    func streamEntry(
        named name: String,
        password: String? = nil,
        chunkSize: Int = 1 << 20,
        sink: (Data) throws -> Void
    ) throws -> Int64 {
        guard let entry = entries[name] else {
            throw ZipReaderError.entryNotFound(name)
        }
        return try streamEntry(entry, password: password, chunkSize: chunkSize, sink: sink)
    }

    /// Streaming variant of `readEntry(_:password:)`. See `streamEntry(named:)`.
    @discardableResult
    func streamEntry(
        _ entry: ZipMember,
        password: String? = nil,
        chunkSize: Int = 1 << 20,
        sink: (Data) throws -> Void
    ) throws -> Int64 {
        guard let range = try storedPayloadRange(for: entry) else {
            // Compressed or encrypted: decode the whole entry through the
            // existing, fully validated path, then hand the bytes over in one
            // piece. Backups never hit this branch, so the multi-gigabyte case
            // always streams.
            let payload = try readEntry(entry, password: password)
            try sink(payload)
            return Int64(payload.count)
        }

        let step = max(chunkSize, 1)
        var crc: uLong = crc32(0, nil, 0)
        var written = 0
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let length = min(step, range.upperBound - cursor)
            let chunk = try source.read(at: cursor, length: length)
            guard !chunk.isEmpty else {
                throw ZipReaderError.invalidArchive("Truncated archive")
            }
            chunk.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                }
            }
            try sink(chunk)
            written += chunk.count
            cursor += chunk.count
        }

        // Same checks `readEntry` performs, just accumulated while streaming.
        if entry.crc32 != 0, UInt32(truncatingIfNeeded: crc) != entry.crc32 {
            throw ZipReaderError.checksumMismatch(entry.name)
        }
        if entry.uncompressedSize > 0, written != entry.uncompressedSize {
            throw ZipReaderError.invalidArchive("Size mismatch for \(entry.name)")
        }
        return Int64(written)
    }

    /// Byte range of the raw payload for a plain stored (method 0, unencrypted)
    /// entry, or `nil` when the entry needs decompression or decryption and
    /// must go through `readEntry` instead.
    ///
    /// The local header is re-read rather than trusted from the central
    /// directory: if it disagrees about the compression method, returning `nil`
    /// routes the entry through the validating whole-entry read instead of
    /// silently streaming bytes that were never meant to be stored verbatim.
    private func storedPayloadRange(for entry: ZipMember) throws -> Range<Int>? {
        guard entry.compression == 0, !entry.isEncrypted else { return nil }
        let localOffset = entry.localHeaderOffset
        guard localOffset >= 0, localOffset + 30 <= source.size else {
            throw ZipReaderError.invalidArchive("Truncated local header for \(entry.name)")
        }
        guard try source.readUInt32(at: localOffset) == 0x04034b50 else {
            throw ZipReaderError.invalidArchive("Bad local header for \(entry.name)")
        }
        let localCompression = Int(try source.readUInt16(at: localOffset + 8))
        guard localCompression == 0 else { return nil }
        let nameLen = Int(try source.readUInt16(at: localOffset + 26))
        let extraLen = Int(try source.readUInt16(at: localOffset + 28))
        let start = localOffset + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard end <= source.size else {
            throw ZipReaderError.invalidArchive("Truncated payload for \(entry.name)")
        }
        return start..<end
    }

    /// Unpack every entry under `destDir`. Rejects `..` paths.
    func extract(into destDir: String, files: FileService, password: String? = nil) throws {
        if needsPassword, password == nil || password?.isEmpty == true {
            throw ZipReaderError.passwordRequired
        }
        let root = (destDir as NSString).standardizingPath
        try files.createDirectory(at: root)
        var fileCount = 0
        var byteCount: Int64 = 0
        for name in entryNames() {
            if name.isEmpty { continue }
            let resolved = try ArchiveEntryPath.resolve(name, under: destDir)
            if resolved.isDirectory {
                try files.createDirectory(at: resolved.path)
                continue
            }
            let payload = try readEntry(named: name, password: password)
            fileCount += 1
            byteCount += Int64(payload.count)
            if fileCount > 20_000 {
                throw FileServiceError.operationFailed("Too many files to extract (20,000 limit).")
            }
            if byteCount > 2_000_000_000 {
                throw FileServiceError.operationFailed("Extracted data would be larger than 2 GB.")
            }
            try files.writeFile(data: payload, to: resolved.path)
        }
    }

    private static func inflateRaw(_ input: Data, expected: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZipReaderError.unsupportedCompression("deflate")
        }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { raw in
            guard let inBase = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw ZipReaderError.invalidArchive("Empty deflate stream")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            var output = Data()
            output.reserveCapacity(max(expected, 64))
            let chunk = 64 * 1024
            var buffer = [Bytef](repeating: 0, count: chunk)
            var status: Int32 = Z_OK
            repeat {
                buffer.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0, let base = buf.baseAddress {
                        output.append(base, count: produced)
                    }
                }
                if output.count > 2_000_000_000 {
                    throw FileServiceError.operationFailed("Extracted data would be larger than 2 GB.")
                }
                if status == Z_STREAM_ERROR || status == Z_DATA_ERROR || status == Z_MEM_ERROR {
                    throw ZipReaderError.invalidArchive("Deflate failed")
                }
            } while status == Z_OK
            guard status == Z_STREAM_END else {
                throw ZipReaderError.invalidArchive("Truncated deflate stream")
            }
            return output
        }
    }

    private func parseCentralDirectory() throws {
        guard source.size >= 22 else {
            throw ZipReaderError.invalidArchive("File too small")
        }

        // The EOCD record sits at the very end of the file, optionally followed
        // by a comment of up to 65,535 bytes. Read only that tail instead of the
        // whole archive, then scan it backwards for the signature.
        let tailLength = min(source.size, 22 + 65_535)
        let tailStart = source.size - tailLength
        let tail = try source.read(at: tailStart, length: tailLength)

        // Prefer an EOCD whose comment length lands exactly on the end of the
        // file (that rules out a signature that merely appears inside file
        // data). Archives with trailing bytes after the EOCD fall back to the
        // last signature found, matching the previous reader's behaviour.
        var eocdIndex: Int?
        var fallbackIndex: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                if fallbackIndex == nil { fallbackIndex = i }
                let commentLength = Int(readLE16(tail, i + 20))
                if i + 22 + commentLength == tail.count {
                    eocdIndex = i
                    break
                }
            }
            i -= 1
        }
        guard let eocdIndex = eocdIndex ?? fallbackIndex else {
            throw ZipReaderError.invalidArchive("End-of-central-directory not found")
        }
        let eocd = tailStart + eocdIndex

        var centralSize = Int(readLE32(tail, eocdIndex + 12))
        var centralOffset = Int(readLE32(tail, eocdIndex + 16))

        // ZIP64: the locator sits immediately before the EOCD and points at a
        // record carrying the 64-bit central directory position. Every step is
        // validated, because the 20 bytes in front of the EOCD can
        // coincidentally look like a locator signature in a plain 32-bit
        // archive. When validation fails the 32-bit values are kept; if they
        // were the 0xFFFFFFFF sentinel the range guard below rejects them.
        if eocd >= 20,
           try source.readUInt32(at: eocd - 20) == ZipFormat.zip64LocatorSignature,
           let zip64Raw = try? source.readUInt64(at: eocd - 12),
           let zip64Offset = Int(exactly: zip64Raw),
           zip64Offset <= eocd - 56,
           (try? source.readUInt32(at: zip64Offset)) == ZipFormat.zip64EOCDSignature {
            centralSize = Int(try source.readUInt64(at: zip64Offset + 40))
            centralOffset = Int(try source.readUInt64(at: zip64Offset + 48))
        }

        guard centralOffset >= 0, centralSize >= 0, centralOffset + centralSize <= source.size else {
            throw ZipReaderError.invalidArchive("Central directory out of range")
        }

        let central = try source.read(at: centralOffset, length: centralSize)
        var offset = 0
        var parsed: [String: ZipMember] = [:]

        while offset + 46 <= central.count {
            guard readLE32(central, offset) == 0x02014b50 else { break }

            let flags = readLE16(central, offset + 8)
            let compression = Int(readLE16(central, offset + 10))
            let dosTime = readLE16(central, offset + 12)
            let crc = readLE32(central, offset + 16)
            var compressed = Int(readLE32(central, offset + 20))
            var uncompressed = Int(readLE32(central, offset + 24))
            let nameLen = Int(readLE16(central, offset + 28))
            let extraLen = Int(readLE16(central, offset + 30))
            let commentLen = Int(readLE16(central, offset + 32))
            var localHeaderOffset = Int(readLE32(central, offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= central.count else {
                throw ZipReaderError.invalidArchive("Truncated entry name")
            }
            let nameData = central.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
            guard let name else {
                throw ZipReaderError.invalidArchive("Unreadable entry name")
            }

            let extraStart = nameEnd
            let extraEnd = extraStart + extraLen
            let extra = extraEnd <= central.count ? central.subdata(in: extraStart..<extraEnd) : Data()
            let aes = Self.parseAESExtra(extra)

            // ZIP64 extended information: substitute the 64-bit values for the
            // fields whose 32-bit counterparts hold the 0xFFFFFFFF sentinel.
            if let zip64 = Self.parseZip64Extra(
                extra,
                needsUncompressedSize: uncompressed == 0xFFFF_FFFF,
                needsCompressedSize: compressed == 0xFFFF_FFFF,
                needsOffset: localHeaderOffset == 0xFFFF_FFFF
            ) {
                if let value = zip64.uncompressedSize { uncompressed = value }
                if let value = zip64.compressedSize { compressed = value }
                if let value = zip64.localHeaderOffset { localHeaderOffset = value }
            }

            parsed[name] = ZipMember(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                crc32: crc,
                localHeaderOffset: localHeaderOffset,
                compression: compression,
                flags: flags,
                dosTime: dosTime,
                aes: aes
            )

            offset = nameEnd + extraLen + commentLen
        }

        guard !parsed.isEmpty else {
            throw ZipReaderError.invalidArchive("No entries found")
        }
        entries = parsed
    }

    private static func parseAESExtra(_ extra: Data) -> ZipAESInfo? {
        var i = 0
        while i + 4 <= extra.count {
            let id = readLE16(extra, i)
            let size = Int(readLE16(extra, i + 2))
            let bodyStart = i + 4
            let bodyEnd = bodyStart + size
            guard bodyEnd <= extra.count else { break }
            if id == 0x9901, size >= 7 {
                let vendor = extra.subdata(in: (bodyStart + 2)..<(bodyStart + 4))
                if vendor == Data([0x41, 0x45]) { // "AE"
                    let strength = extra[bodyStart + 4]
                    let method = Int(readLE16(extra, bodyStart + 5))
                    let bits: Int
                    switch strength {
                    case 1: bits = 128
                    case 2: bits = 192
                    case 3: bits = 256
                    default: return nil
                    }
                    return ZipAESInfo(keyBits: bits, compression: method)
                }
            }
            i = bodyEnd
        }
        return nil
    }

    /// Parse the ZIP64 extended information extra field (`0x0001`). Only the
    /// values whose fixed field was the 0xFFFFFFFF sentinel are present, and
    /// they appear in the fixed order: uncompressed size, compressed size,
    /// relative header offset, disk start number.
    private static func parseZip64Extra(
        _ extra: Data,
        needsUncompressedSize: Bool,
        needsCompressedSize: Bool,
        needsOffset: Bool
    ) -> (uncompressedSize: Int?, compressedSize: Int?, localHeaderOffset: Int?)? {
        guard needsUncompressedSize || needsCompressedSize || needsOffset else { return nil }
        var i = 0
        while i + 4 <= extra.count {
            let id = readLE16(extra, i)
            let size = Int(readLE16(extra, i + 2))
            let bodyStart = i + 4
            let bodyEnd = bodyStart + size
            guard bodyEnd <= extra.count else { break }
            if id == ZipFormat.zip64ExtraID {
                var cursor = bodyStart
                var uncompressed: Int?
                var compressed: Int?
                var headerOffset: Int?
                if needsUncompressedSize, cursor + 8 <= bodyEnd {
                    uncompressed = Int(readLE64(extra, cursor))
                    cursor += 8
                }
                if needsCompressedSize, cursor + 8 <= bodyEnd {
                    compressed = Int(readLE64(extra, cursor))
                    cursor += 8
                }
                if needsOffset, cursor + 8 <= bodyEnd {
                    headerOffset = Int(readLE64(extra, cursor))
                }
                return (uncompressed, compressed, headerOffset)
            }
            i = bodyEnd
        }
        return nil
    }
}

// MARK: - Little-endian byte helpers

private func readLE16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[offset + i]) << (8 * i)
    }
    return value
}

private extension ZipByteSource {
    func readUInt16(at offset: Int) throws -> UInt16 {
        readLE16(try read(at: offset, length: 2), 0)
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        readLE32(try read(at: offset, length: 4), 0)
    }

    func readUInt64(at offset: Int) throws -> UInt64 {
        readLE64(try read(at: offset, length: 8), 0)
    }
}
