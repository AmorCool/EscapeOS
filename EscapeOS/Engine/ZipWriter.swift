import Foundation
import CryptoKit
import zlib

/// A single file recorded in a backup archive's manifest.
struct BackupManifestEntry: Codable {
    let path: String
    let size: Int
    let sha256: String
}

/// ZIP container constants shared by `ZipWriter` and `ZipReader`.
enum ZipFormat {
    /// Largest value a 32-bit ZIP size / offset field can hold. Anything at or
    /// above this must be carried by a ZIP64 extended-information extra field
    /// instead; the fixed 32-bit field then holds the `0xFFFFFFFF` sentinel.
    static let zip64Threshold: UInt64 = 0xFFFF_FFFF
    /// Header id of the ZIP64 extended information extra field (`0x0001`).
    static let zip64ExtraID: UInt16 = 0x0001
    /// ZIP64 end-of-central-directory record signature (`PK\x06\x06`).
    static let zip64EOCDSignature: UInt32 = 0x06064b50
    /// ZIP64 end-of-central-directory locator signature (`PK\x06\x07`).
    static let zip64LocatorSignature: UInt32 = 0x07064b50
}

/// Errors thrown while producing a ZIP archive.
enum ZipWriterError: Error, LocalizedError {
    /// `begin(at:)` was not called (or the archive was already finished).
    case notBegun
    /// The source file could not be opened for reading. Nothing has been
    /// written to the archive yet, so callers may safely skip this file.
    case cannotReadSource(String)
    /// The source file crossed the ZIP64 threshold after its local header had
    /// already been written, so the header layout can no longer be fixed.
    case sourceChangedDuringWrite(String)

    var errorDescription: String? {
        switch self {
        case .notBegun:
            return "ZipWriter has not been started."
        case .cannotReadSource(let path):
            return "Could not read file for archiving: \(path)"
        case .sourceChangedDuringWrite(let name):
            return "File changed size while being archived: \(name)"
        }
    }
}

/// Result of storing one file in an archive.
struct ZipAddedFile {
    /// Bytes actually stored (uncompressed, since the archive is store-only).
    let size: Int64
    /// Lower-case hex SHA-256 of the stored bytes. Backups embed this in their
    /// manifest, so computing it while streaming avoids a second read pass.
    let sha256: String
}

/// Store-only ZIP writer for backups and Compress. Files are stored uncompressed
/// (DEFLATE adds little for already-compressed app data).
///
/// Layout notes (v0.3.531):
/// - Small archives are byte-for-byte identical to the pre-ZIP64 writer, so
///   existing readers (including older EscapeSpace builds) keep working.
/// - Sizes / offsets at or above 4 GiB are written through a ZIP64 extended
///   information extra field, and a ZIP64 end-of-central-directory record is
///   emitted when the entry count or central directory overflows 32 bits.
/// - `addFile(name:path:...)` streams from disk, so a multi-gigabyte file is
///   never materialised in memory.
final class ZipWriter {

    private var fileHandle: FileHandle?
    private var centralDirectory: [CentralRecord] = []
    private var offset: UInt64 = 0

    struct CentralRecord {
        let name: String
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }

    /// Begin writing a new zip at `url`. Any existing file is truncated.
    func begin(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.fileHandle = handle
        self.centralDirectory = []
        self.offset = 0
    }

    /// Add an in-memory blob to the archive. `data` is stored uncompressed
    /// under `name`. Kept for manifest / metadata entries and for the Compress
    /// feature, whose payloads are already in memory.
    @discardableResult
    func addFile(name: String, data: Data, modified: Date = Date()) throws -> ZipAddedFile {
        var cursor = 0
        return try addStream(
            name: name,
            expectedSize: Int64(data.count),
            modified: modified
        ) { maxLength in
            guard cursor < data.count else { return nil }
            let end = min(cursor + maxLength, data.count)
            let chunk = data.subdata(in: cursor..<end)
            cursor = end
            return chunk
        }
    }

    /// Stream a file from disk into the archive without loading it into memory.
    ///
    /// `expectedSize` is the size reported by `stat` before the read; it only
    /// decides whether the local header needs a ZIP64 extra field. The real
    /// size is patched in afterwards when it differs (a file may grow while it
    /// is being archived).
    ///
    /// Throws `ZipWriterError.cannotReadSource` when the file cannot be opened
    /// (nothing has been written yet, so the caller may skip it). Any other
    /// error means a partial entry is already on disk, and the caller must
    /// discard the whole archive.
    @discardableResult
    func addFile(name: String, path: String, expectedSize: Int64, modified: Date = Date()) throws -> ZipAddedFile {
        guard fileHandle != nil else { throw ZipWriterError.notBegun }
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw ZipWriterError.cannotReadSource(path)
        }
        defer { try? source.close() }
        return try addStream(
            name: name,
            expectedSize: max(expectedSize, 0),
            modified: modified
        ) { maxLength in
            try source.read(upToCount: maxLength)
        }
    }

    /// Finalize the archive (writes central directory + end record).
    func finish() throws {
        guard let handle = fileHandle else { return }
        let centralStart = offset

        for record in centralDirectory {
            let nameData = Array(record.name.utf8)
            let needsSize64 = record.size >= ZipFormat.zip64Threshold
            let needsOffset64 = record.localHeaderOffset >= ZipFormat.zip64Threshold
            let usesZip64 = needsSize64 || needsOffset64

            // ZIP64 extra body: fields appear only for the fixed 32-bit fields
            // that were replaced by the 0xFFFFFFFF sentinel, in the fixed order
            // (original size, compressed size, relative header offset).
            var extraBody = Data()
            if needsSize64 {
                extraBody.appendLE(record.size)
                extraBody.appendLE(record.size)
            }
            if needsOffset64 {
                extraBody.appendLE(record.localHeaderOffset)
            }
            var extra = Data()
            if !extraBody.isEmpty {
                extra.appendLE(ZipFormat.zip64ExtraID)
                extra.appendLE(UInt16(extraBody.count))
                extra.append(extraBody)
            }

            let sizeField = needsSize64 ? UInt32(0xFFFF_FFFF) : UInt32(truncatingIfNeeded: record.size)
            let offsetField = needsOffset64
                ? UInt32(0xFFFF_FFFF)
                : UInt32(truncatingIfNeeded: record.localHeaderOffset)

            var central = Data()
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            central.appendLE(UInt16(usesZip64 ? 45 : 20)) // version made by
            central.appendLE(UInt16(usesZip64 ? 45 : 20)) // version needed
            central.appendLE(UInt16(0))      // flags
            central.appendLE(UInt16(0))      // compression
            central.appendLE(record.dosTime)
            central.appendLE(record.dosDate)
            central.appendLE(record.crc32)
            central.appendLE(sizeField)      // compressed
            central.appendLE(sizeField)      // uncompressed
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(extra.count))
            central.appendLE(UInt16(0))      // comment
            central.appendLE(UInt16(0))      // disk number
            central.appendLE(UInt16(0))      // internal attrs
            central.appendLE(UInt32(0))      // external attrs
            central.appendLE(offsetField)
            central.append(contentsOf: nameData)
            central.append(extra)
            handle.write(central)
            offset += UInt64(central.count)
        }

        let centralSize = offset - centralStart
        let entryCount = centralDirectory.count
        let needsZip64EOCD = entryCount > 0xFFFF
            || centralSize >= ZipFormat.zip64Threshold
            || centralStart >= ZipFormat.zip64Threshold

        if needsZip64EOCD {
            // ZIP64 end-of-central-directory record.
            let eocd64Start = offset
            var record = Data()
            record.append(contentsOf: [0x50, 0x4B, 0x06, 0x06])
            record.appendLE(UInt64(44))              // size of the remaining record
            record.appendLE(UInt16(45))              // version made by
            record.appendLE(UInt16(45))              // version needed
            record.appendLE(UInt32(0))               // this disk
            record.appendLE(UInt32(0))               // disk with central directory
            record.appendLE(UInt64(entryCount))      // entries on this disk
            record.appendLE(UInt64(entryCount))      // total entries
            record.appendLE(centralSize)
            record.appendLE(centralStart)
            handle.write(record)
            offset += UInt64(record.count)

            // ZIP64 end-of-central-directory locator, pointing back at it.
            var locator = Data()
            locator.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])
            locator.appendLE(UInt32(0))              // disk with ZIP64 EOCD
            locator.appendLE(eocd64Start)
            locator.appendLE(UInt32(1))              // total disks
            handle.write(locator)
            offset += UInt64(locator.count)
        }

        var end = Data()
        end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD signature
        end.appendLE(UInt16(0))  // disk
        end.appendLE(UInt16(0))  // disk with central
        end.appendLE(entryCount > 0xFFFF ? UInt16(0xFFFF) : UInt16(entryCount))
        end.appendLE(entryCount > 0xFFFF ? UInt16(0xFFFF) : UInt16(entryCount))
        end.appendLE(
            centralSize >= ZipFormat.zip64Threshold
                ? UInt32(0xFFFF_FFFF)
                : UInt32(truncatingIfNeeded: centralSize)
        )
        end.appendLE(
            centralStart >= ZipFormat.zip64Threshold
                ? UInt32(0xFFFF_FFFF)
                : UInt32(truncatingIfNeeded: centralStart)
        )
        end.appendLE(UInt16(0))  // comment length
        handle.write(end)

        try handle.close()
        fileHandle = nil
    }

    // MARK: - Streaming core

    /// Write one entry by pulling chunks from `readChunk` (nil = end of input).
    ///
    /// The local header must precede the payload, but the CRC is only known
    /// once the payload has been read, so a zero CRC is written first and then
    /// patched in place. The header length does not change, so the ZIP layout
    /// is unaffected and small archives stay byte-identical to the old writer.
    private func addStream(
        name: String,
        expectedSize: Int64,
        modified: Date,
        readChunk: (Int) throws -> Data?
    ) throws -> ZipAddedFile {
        guard let handle = fileHandle else { throw ZipWriterError.notBegun }

        let nameData = Array(name.utf8)
        let (dosTime, dosDate) = Self.msdosTimestamp(from: modified)
        let localOffset = offset
        let predicted = UInt64(max(expectedSize, 0))
        let usesZip64 = predicted >= ZipFormat.zip64Threshold

        // ZIP64 local extra: original size + compressed size (8 bytes each).
        // Only emitted when the file is large enough that the fixed 32-bit
        // fields would overflow, so small archives are unchanged.
        var extra = Data()
        if usesZip64 {
            extra.appendLE(ZipFormat.zip64ExtraID)
            extra.appendLE(UInt16(16))
            extra.appendLE(predicted)
            extra.appendLE(predicted)
        }
        let sizeField = usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(truncatingIfNeeded: predicted)

        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
        header.appendLE(UInt16(usesZip64 ? 45 : 20)) // version needed
        header.appendLE(UInt16(0))         // flags
        header.appendLE(UInt16(0))         // compression = store
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(UInt32(0))         // crc32, patched after streaming
        header.appendLE(sizeField)         // compressed size
        header.appendLE(sizeField)         // uncompressed size
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(extra.count))
        header.append(contentsOf: nameData)
        header.append(extra)

        handle.write(header)
        offset += UInt64(header.count)

        var crc: uLong = crc32(0, nil, 0)
        var hasher = SHA256()
        var written: Int64 = 0
        let chunkSize = 1 << 20
        while let chunk = try readChunk(chunkSize), !chunk.isEmpty {
            chunk.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                }
            }
            hasher.update(data: chunk)
            handle.write(chunk)
            written += Int64(chunk.count)
            offset += UInt64(chunk.count)
        }

        let crcValue = UInt32(truncatingIfNeeded: crc)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        try patch(at: localOffset + 14, bytes: Self.leBytes(crcValue))
        if UInt64(written) != predicted {
            // The file changed size between `stat` and the read. The header was
            // already laid out for `predicted`, so the new size must be patched.
            if !usesZip64 && UInt64(written) >= ZipFormat.zip64Threshold {
                throw ZipWriterError.sourceChangedDuringWrite(name)
            }
            if usesZip64 {
                // Local extra body starts after the 30-byte header + name + the
                // 4-byte extra-field header (id + length).
                let extraBody = localOffset + 30 + UInt64(nameData.count) + 4
                try patch(at: extraBody, bytes: Self.leBytes(UInt64(written)))
                try patch(at: extraBody + 8, bytes: Self.leBytes(UInt64(written)))
            } else {
                try patch(at: localOffset + 18, bytes: Self.leBytes(UInt32(truncatingIfNeeded: written)))
                try patch(at: localOffset + 22, bytes: Self.leBytes(UInt32(truncatingIfNeeded: written)))
            }
        }

        centralDirectory.append(CentralRecord(
            name: name,
            crc32: crcValue,
            size: UInt64(written),
            localHeaderOffset: localOffset,
            dosTime: dosTime,
            dosDate: dosDate
        ))

        return ZipAddedFile(size: written, sha256: digest)
    }

    /// Overwrite `bytes` at `offset`, then restore the cursor to the end of the
    /// archive so the next entry keeps appending.
    private func patch(at offset: UInt64, bytes: Data) throws {
        guard let handle = fileHandle else { throw ZipWriterError.notBegun }
        let end = self.offset
        try handle.seek(toOffset: offset)
        handle.write(bytes)
        try handle.seek(toOffset: end)
    }

    private static func leBytes(_ value: UInt32) -> Data {
        var data = Data()
        data.appendLE(value)
        return data
    }

    private static func leBytes(_ value: UInt64) -> Data {
        var data = Data()
        data.appendLE(value)
        return data
    }

    /// MS-DOS time/date used by ZIP local and central headers.
    private static func msdosTimestamp(from date: Date) -> (UInt16, UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone.current, from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = (c.second ?? 0) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    /// Pack files and folders into this archive. Directory entries keep their
    /// top-level names (`Caches/foo.plist`). `skipPath` is the zip being written
    /// so a folder compress never includes itself.
    func addItems(_ items: [FileItem], files: FileService, skipPath: String) throws {
        var fileCount = 0
        var byteCount: Int64 = 0
        for item in items {
            try addEntry(
                path: item.path,
                archiveName: item.name,
                files: files,
                skipPath: skipPath,
                fileCount: &fileCount,
                byteCount: &byteCount
            )
        }
        if fileCount == 0 && centralDirectory.isEmpty {
            throw FileServiceError.operationFailed("Nothing to zip.")
        }
    }

    private func addEntry(
        path: String,
        archiveName: String,
        files: FileService,
        skipPath: String,
        fileCount: inout Int,
        byteCount: inout Int64
    ) throws {
        let standardized = (path as NSString).standardizingPath
        let skip = (skipPath as NSString).standardizingPath
        if standardized == skip || standardized.hasPrefix(skip + "/") {
            return
        }
        if files.isDirectory(at: path) {
            let children = try files.list(directory: path)
            if children.isEmpty {
                try addFile(name: archiveName.hasSuffix("/") ? archiveName : archiveName + "/", data: Data())
                return
            }
            for child in children {
                try addEntry(
                    path: child.path,
                    archiveName: archiveName + "/" + child.name,
                    files: files,
                    skipPath: skipPath,
                    fileCount: &fileCount,
                    byteCount: &byteCount
                )
            }
            return
        }
        fileCount += 1
        if fileCount > 20_000 {
            throw FileServiceError.operationFailed("Too many files to zip (20,000 limit).")
        }
        // Stream from disk instead of reading the whole file into memory, so
        // the Compress feature also survives multi-gigabyte inputs.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let added = try addFile(name: archiveName, path: path, expectedSize: size, modified: Date())
        byteCount += added.size
        if byteCount > 2_000_000_000 {
            throw FileServiceError.operationFailed("Zip would be larger than 2 GB.")
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
