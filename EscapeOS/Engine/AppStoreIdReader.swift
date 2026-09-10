//
//  AppStoreIdReader.swift
//  EscapeOS
//
//  v0.3.281：读取「已安装 App 的安装来源 Apple ID」——爱思助手同款通道。
//
//  通道（逆向 i4Tools 的 idm_app.dll 实锤：/PublicStaging/ + SkipUninstall +
//  am_archive_app + iTunesMetadata 字符串并存 + am_get_device_app_iTunesMetadata 导出）：
//    1. instproxy `Archive` 把 App 归档到设备 /PublicStaging/<bundleId>.ipa
//       （归档包内含 iTunesMetadata.plist —— 该文件只在 bundle 目录，
//        house_arrest/AFC 对 bundle 均不可达，Archive 是非越狱唯一导出路径）
//    2. AFC（媒体根 /var/mobile/Media）读到本地
//    3. 解析 zip 取出 iTunesMetadata.plist → appleId
//    4. 删除设备上的归档文件（清理）
//
//  注意：Archive 耗时/占盘 ≈ App 大小；调用方应在后台线程执行并在 UI 提示。
//

import Foundation
import Compression

enum AppStoreIdReader {

    /// 读取结果（appleId 可能为空串：非 App Store 安装的包没有该字段）
    struct Result {
        var appleId: String
        var purchaseDate: String?
    }

    // MARK: - 对外入口

    /// 读指定 App 的安装来源 Apple ID（同步阻塞，调用方放后台线程）。
    static func installingAppleId(bundleId: String, log: ((String) -> Void)? = nil) throws -> Result {
        log?("开始归档 \(bundleId)（Archive 到 /PublicStaging，耗时与 App 大小成正比）…")
        try archiveApp(bundleId: bundleId, log: log)
        defer { removeArchivedApp(bundleId: bundleId, log: log) }

        log?("归档完成，读取归档包并解析 iTunesMetadata…")
        let afc = try openMediaAFC()
        defer { afc_client_free(afc) }

        let path = "/PublicStaging/\(bundleId).ipa"
        let size = try fileSize(afc: afc, path: path)
        guard size > 22 else { throw makeError("归档文件异常（\(size) 字节）") }
        log?("归档大小 \(size / 1024 / 1024) MB，定位 zip 中央目录…")

        let metaData = try readZipEntry(afc: afc, path: path, fileSize: size, entryName: "iTunesMetadata.plist")
        guard let dict = (try? PropertyListSerialization.propertyList(from: metaData, format: nil)) as? [String: Any] else {
            throw makeError("iTunesMetadata.plist 解析失败")
        }
        let appleId = (dict["appleId"] as? String)
            ?? (dict["purchaseAccountID"] as? String)
            ?? (dict["bpsAccountID"] as? String)
            ?? ""
        let date = (dict["purchaseDate"] as? Date).map { ISO8601DateFormatter().string(from: $0) }
        log?("解析完成：appleId=\(appleId.isEmpty ? "(空)" : appleId)")
        return Result(appleId: appleId, purchaseDate: date)
    }

    // MARK: - 导出 IPA（爱思「导出应用」同款：Archive → 拉回本机）

    /// 把指定 App 归档并完整拉回本机 Documents/AppStoreDownloads/<bundleId>.ipa。
    /// 归档包即 App Store 风格 IPA（含 Payload/ + iTunesMetadata.plist），可再次安装。
    /// 同步阻塞；progress 回调 0...1。
    static func exportIPA(bundleId: String,
                          log: ((String) -> Void)? = nil,
                          progress: ((Double) -> Void)? = nil) throws -> URL {
        log?("开始归档 \(bundleId) 到设备…")
        try archiveApp(bundleId: bundleId, log: log)
        defer { removeArchivedApp(bundleId: bundleId, log: log) }

        let afc = try openMediaAFC()
        defer { afc_client_free(afc) }
        let devicePath = "/PublicStaging/\(bundleId).ipa"
        let size = try fileSize(afc: afc, path: devicePath)
        guard size > 0 else { throw makeError("归档文件为空") }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outDir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(bundleId).ipa")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outURL.path) else {
            throw makeError("无法创建本地文件")
        }
        defer { try? handle.close() }

        // 分块从设备读 → 写本地（1MB/块，对齐 CrashLogService 结论）
        var handleDevice: OpaquePointer?
        if let e = devicePath.withCString({ afc_file_open(afc, $0, AfcRdOnly, &handleDevice) }) {
            idevice_error_free(e)
            throw makeError("打开设备归档失败")
        }
        guard let handleDevice else { throw makeError("打开设备归档失败（空句柄）") }
        defer { afc_file_close(handleDevice) }

        var offset: Int64 = 0
        let chunk = 1 << 20
        while offset < size {
            let want = Int(min(Int64(chunk), size - offset))
            var buf: UnsafeMutablePointer<UInt8>?
            var got: Int = 0
            if let e = afc_file_read(handleDevice, &buf, UInt(want), &got) {
                idevice_error_free(e)
                throw makeError("读取归档失败（offset=\(offset)）")
            }
            guard let buf, got > 0 else { break }
            handle.write(Data(bytes: buf, count: got))
            afc_file_read_data_free(buf, got)
            offset += Int64(got)
            progress?(Double(offset) / Double(size))
        }
        log?("导出完成：\(outURL.lastPathComponent)（\(size / 1024 / 1024) MB）")
        return outURL
    }

    // MARK: - 1) instproxy Archive

    private static func archiveApp(bundleId: String, log: ((String) -> Void)?) throws {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ip: OpaquePointer?
        guard installation_proxy_connect_rsd(adapter, handshake, &ip) == nil, let ip else {
            throw makeError("连接 instproxy 失败")
        }
        defer { installation_proxy_client_free(ip) }

        let err = bundleId.withCString { bid in
            installation_proxy_archive(ip, bid, true)
        }
        if let err {
            let msg = ffiErrorText(err)
            idevice_error_free(err)
            throw makeError("Archive 失败：\(msg)")
        }
        _ = log
    }

    private static func removeArchivedApp(bundleId: String, log: ((String) -> Void)?) {
        guard let afc = try? openMediaAFC() else { return }
        defer { afc_client_free(afc) }
        let path = "/PublicStaging/\(bundleId).ipa"
        let rc = path.withCString { afc_remove_path(afc, $0) }
        if rc == nil {
            log?("已清理设备上的归档文件")
        } else {
            log?("清理归档文件失败（可忽略，文件位于设备 /PublicStaging/）")
        }
    }

    // MARK: - 2) AFC（媒体根 = /var/mobile/Media）

    private static func openMediaAFC() throws -> OpaquePointer {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var client: OpaquePointer?
        // RSD 铁律：afc_client_connect_rsd 需要退避重试
        for attempt in 1...3 {
            if afc_client_connect_rsd(adapter, handshake, &client) == nil, let client {
                return client
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.4 * Double(attempt)) }
        }
        throw makeError("连接 AFC（com.apple.afc）失败")
    }

    private static func fileSize(afc: OpaquePointer, path: String) throws -> Int64 {
        var info = AfcFileInfo()
        let rc = path.withCString { afc_get_file_info(afc, $0, &info) }
        defer { afc_file_info_free(&info) }
        guard rc == nil, info.size > 0 else { throw makeError("读取归档文件信息失败") }
        return Int64(info.size)
    }

    /// 从 AFC 读 [offset, offset+length) 区段
    private static func readRange(afc: OpaquePointer, path: String, offset: Int64, length: Int) throws -> Data {
        var handle: OpaquePointer?
        if let e = path.withCString({ afc_file_open(afc, $0, AfcRdOnly, &handle) }) {
            idevice_error_free(e)
            throw makeError("打开归档文件失败")
        }
        guard let handle else { throw makeError("打开归档文件失败（空句柄）") }
        defer { afc_file_close(handle) }

        var newPos: Int64 = 0
        if let e = afc_file_seek(handle, offset, SEEK_SET, &newPos) {
            idevice_error_free(e)
            throw makeError("定位归档文件失败（offset=\(offset)）")
        }

        var out = Data()
        out.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            let chunk = min(remaining, 1 << 20) // 1MB 分块（对齐 CrashLogService 结论）
            var buf: UnsafeMutablePointer<UInt8>?
            var got: Int = 0
            if let e = afc_file_read(handle, &buf, UInt(chunk), &got) {
                idevice_error_free(e)
                throw makeError("读取归档文件失败")
            }
            guard let buf, got > 0 else { break }
            out.append(Data(bytes: buf, count: got))
            afc_file_read_data_free(buf, got)
            remaining -= got
        }
        return out
    }

    // MARK: - 3) zip 解析（中央目录 → 目标条目 → 解压）

    /// 从 zip 中提取单个条目（支持 stored / deflate）
    private static func readZipEntry(afc: OpaquePointer, path: String, fileSize: Int64, entryName: String) throws -> Data {
        // 3.1 找 EOCD（尾部最多 64KB + 22）
        let tailLen = min(Int(fileSize), 65558)
        let tail = try readRange(afc: afc, path: path, offset: fileSize - Int64(tailLen), length: tailLen)
        guard let eocdOffset = findEOCD(in: tail) else { throw makeError("zip EOCD 未找到") }

        let cdSize = Int(readU32(tail, eocdOffset + 12))
        let cdOffset = Int64(readU32(tail, eocdOffset + 16))

        // 3.2 读中央目录
        let cd = try readRange(afc: afc, path: path, offset: cdOffset, length: cdSize)

        // 3.3 遍历中央目录项找目标
        var p = 0
        while p + 46 <= cd.count {
            guard readU32(cd, p) == 0x02014b50 else { break }
            let method = Int(readU16(cd, p + 10))
            let compSize = Int64(readU32(cd, p + 20))
            let uncompSize = Int(readU32(cd, p + 24))
            let nameLen = Int(readU16(cd, p + 28))
            let extraLen = Int(readU16(cd, p + 30))
            let commentLen = Int(readU16(cd, p + 32))
            let localOffset = Int64(readU32(cd, p + 42))
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(data: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) ?? ""

            if name == entryName || name.hasSuffix("/" + entryName) {
                // 3.4 读本地头（含真实数据偏移）
                let lh = try readRange(afc: afc, path: path, offset: localOffset, length: 30)
                guard readU32(lh, 0) == 0x04034b50 else { throw makeError("zip 本地头签名错误") }
                let lNameLen = Int(readU16(lh, 26))
                let lExtraLen = Int(readU16(lh, 28))
                let dataOffset = localOffset + 30 + Int64(lNameLen) + Int64(lExtraLen)

                let raw = try readRange(afc: afc, path: path, offset: dataOffset, length: Int(compSize))
                switch method {
                case 0:
                    return raw
                case 8:
                    guard let inflated = inflate(raw, expectedSize: uncompSize) else {
                        throw makeError("zip 解压失败（deflate）")
                    }
                    return inflated
                default:
                    throw makeError("zip 压缩方法不支持：\(method)")
                }
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        throw makeError("归档包内未找到 \(entryName)")
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        while i >= 0 {
            if readU32(data, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func readU16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }

    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[d.startIndex + o])
            | (UInt32(d[d.startIndex + o + 1]) << 8)
            | (UInt32(d[d.startIndex + o + 2]) << 16)
            | (UInt32(d[d.startIndex + o + 3]) << 24)
    }

    /// raw deflate 解压（zip 的 method 8；COMPRESSION_ZLIB 即 raw DEFLATE 流）
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, !input.isEmpty else { return nil }
        var out = Data(count: expectedSize)
        let written: Int = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return out
    }

    // MARK: - 基础设施（复用 FileSharingService 的隧道与错误工具）

    private static func makeTunnel() throws -> FileSharingService.TunnelHandles {
        try FileSharingService.makeTunnel()
    }

    private static func ffiErrorText(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        guard let cstr = err.pointee.message else { return "code=\(err.pointee.code)" }
        return String(cString: cstr)
    }

    private static func makeError(_ message: String) -> NSError {
        FileSharingService.makeError(message)
    }
}
