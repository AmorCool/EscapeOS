import Foundation
import UIKit
import Compression
import Darwin

/// KernelCache 下载服务 —— **IPSW Range 直拉方案**（v0.2.133）。
///
/// 背景：lara 的 `fetchkcache` 依赖内核漏洞（dirty sheep + vn_fileredirect
/// vnode 重定向），EscapeOS 是 LiveContainer 访客沙盒，无 exploit 能力，
/// 无法照搬。替代方案（用户确认）：
///
/// 1. 用 `hw.machine` 拿当前设备型号（如 iPhone13,1），`UIDevice` 拿系统版本；
/// 2. 查 ipsw.me API 找到该版本对应 IPSW 的下载 URL；
/// 3. 对 IPSW（ZIP64 大文件，数 GB）发 Range 请求：先拉尾部 256KB 解析
///    ZIP64 中央目录，定位 `kernelcache.release.<型号>` 条目偏移（实测
///    iPhone13,1/16.3.1 为 ~19.2MB deflate 压缩）；
/// 4. 按偏移 Range 分块下载压缩数据 → raw deflate 解压 → 校验 magic
///    `0x30 0x84`（LZSS kernelcache 标志，与 lara 的校验一致）→ 保存到
///    Documents/KernelCache/。
///
/// 纯网络、零权限、零漏洞，与 lara 从设备读到的 kernelcache 是同一份文件。
final class KernelCacheService {

    static let shared = KernelCacheService()
    private init() {}

    /// 已解析的固件信息。
    struct Firmware {
        let version: String
        let buildid: String
        let url: String
    }

    /// 本地保存目录（文件 App 可见）。
    static var saveDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("KernelCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - 设备信息

    /// 当前设备型号标识（hw.machine，如 "iPhone13,1"）。
    func deviceIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// 当前系统版本（如 "16.3.1"）。
    func systemVersion() -> String {
        UIDevice.current.systemVersion
    }

    // MARK: - 固件查询（ipsw.me）

    /// 查询指定设备、指定版本对应的 IPSW 固件信息。
    /// 同版本多个 build 时取 release date 最新的。
    func findFirmware(identifier: String, version: String) async throws -> Firmware {
        guard let url = URL(string: "https://api.ipsw.me/v4/device/\(identifier)") else {
            throw makeError("无法构造 ipsw.me 查询 URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw makeError("ipsw.me 查询失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let firmwares = json["firmwares"] as? [[String: Any]] else {
            throw makeError("ipsw.me 返回数据格式异常")
        }
        let matches = firmwares.filter { ($0["version"] as? String) == version }
        guard !matches.isEmpty else {
            throw makeError("未找到 \(identifier) 的 iOS \(version) 固件")
        }
        let sorted = matches.sorted {
            ($0["releasedate"] as? String ?? "") > ($1["releasedate"] as? String ?? "")
        }
        guard let best = sorted.first,
              let buildid = best["buildid"] as? String,
              let fwURL = best["url"] as? String else {
            throw makeError("固件信息字段缺失")
        }
        return Firmware(version: version, buildid: buildid, url: fwURL)
    }

    // MARK: - 下载

    /// 从 IPSW 下载并解压 kernelcache，保存到 Documents/KernelCache/，
    /// 返回保存路径。`progress` 在主线程回调（0...1）。
    func downloadKernelCache(firmware: Firmware,
                             progress: @escaping (Double) -> Void) async throws -> String {
        guard let url = URL(string: firmware.url) else {
            throw makeError("IPSW URL 无效")
        }

        // 1. 拉尾部 256KB，解析 ZIP64 中央目录
        let tail = try await fetchRange(url: url, range: "bytes=-262144")
        let (cdOffset, cdSize) = try locateCentralDirectory(tail: tail, url: url)
        let centralDir = try await fetchRange(url: url,
                                              range: "bytes=\(cdOffset)-\(cdOffset + cdSize - 1)")

        // 2. 在中央目录里找 kernelcache.release.* 条目
        guard let entry = findKernelEntry(centralDir: centralDir) else {
            throw makeError("IPSW 中未找到 kernelcache.release 条目")
        }

        // 3. 按偏移 Range 分块下载压缩数据。
        //    data 偏移 = local header 起点 + 30 字节头 + 真实 nlen/xlen
        //    （以 local header 为准，中央目录的 nlen/xlen 理论可能不同）。
        let localHeader = try await fetchRange(url: url,
                                               range: "bytes=\(entry.localHeaderOffset)-\(entry.localHeaderOffset + 59)")
        let localBytes = [UInt8](localHeader)
        guard readUInt32(localBytes, 0) == 0x04034b50 else {
            throw makeError("local header 签名校验失败")
        }
        let localNameLength = Int(readUInt16(localBytes, 26))
        let localExtraLength = Int(readUInt16(localBytes, 28))
        let dataOffset = entry.localHeaderOffset + 30 + localNameLength + localExtraLength
        let total = entry.compressedSize
        var compressed = Data()
        var position = dataOffset
        let chunkSize = 4 * 1024 * 1024
        while position < dataOffset + total {
            let end = min(position + chunkSize - 1, dataOffset + total - 1)
            let chunk = try await fetchRange(url: url, range: "bytes=\(position)-\(end)")
            compressed.append(chunk)
            position += chunk.count
            let fraction = Double(position - dataOffset) / Double(total)
            await MainActor.run { progress(min(fraction, 1.0)) }
        }

        // 4. raw deflate 解压
        guard let inflated = inflateRawDeflate(compressed, expectedSize: entry.uncompressedSize) else {
            throw makeError("kernelcache 数据解压失败")
        }

        // 5. 校验 magic（0x30 0x84 = LZSS kernelcache，与 lara 一致）
        guard inflated.count >= 2,
              inflated[0] == 0x30, inflated[1] == 0x84 else {
            throw makeError("kernelcache 头校验失败（非 0x30 0x84）")
        }

        // 6. 保存
        let fileName = "kernelcache-\(firmware.buildid)"
        let target = URL(fileURLWithPath: Self.saveDirectory).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try inflated.write(to: target)
        await MainActor.run { progress(1.0) }
        return target.path
    }

    // MARK: - ZIP64 解析

    /// 从 IPSW 尾部数据定位 ZIP64 中央目录（返回 offset 与 size）。
    private func locateCentralDirectory(tail: Data, url: URL) throws -> (UInt64, UInt64) {
        // EOCD: PK\x05\x06（从尾部往前找，签名 0x06054b50）
        let bytes = [UInt8](tail)
        var eocdIndex: Int? = nil
        let minIndex = max(0, bytes.count - 0x10000 - 21)
        var i = bytes.count - 4
        while i >= minIndex {
            if readUInt32(bytes, i) == 0x06054b50 {
                eocdIndex = i
                break
            }
            i -= 1
        }
        guard let eocdIndex else {
            throw makeError("IPSW 尾部未找到 EOCD 记录")
        }
        // ZIP64 locator 在 EOCD 前 20 字节：sig(4) + disk(4) + cd64Off(8) + total(4)
        let locatorOffset = eocdIndex - 20
        guard locatorOffset >= 0, readUInt32(bytes, locatorOffset) == 0x07064b50 else {
            throw makeError("未找到 ZIP64 locator（IPSW 不是 ZIP64？）")
        }
        let cd64Offset = readUInt64(bytes, locatorOffset + 8)

        // 拉 ZIP64 EOCD（56 字节）：sig(4)+size(8)+ver(2)+vneed(2)+disk(4)+cddisk(4)
        // +nentry(8)+nentryTotal(8)+cdSize(8)+cdOffset(8)
        let cd64 = try await fetchRange(url: url, range: "bytes=\(cd64Offset)-\(cd64Offset + 55)")
        guard readUInt32(cd64, 0) == 0x06064b50 else {
            throw makeError("ZIP64 EOCD 签名校验失败")
        }
        let cdSize = readUInt64(cd64, 40)
        let cdOffset = readUInt64(cd64, 48)
        guard cdSize > 0, cdSize < 16 * 1024 * 1024 else {
            throw makeError("中央目录大小异常（\(cdSize)）")
        }
        return (cdOffset, cdSize)
    }

    /// 在中央目录中查找 kernelcache.release 条目。
    private func findKernelEntry(centralDir: Data) -> ZipEntry? {
        var pos = 0
        let bytes = [UInt8](centralDir)
        while pos + 46 <= bytes.count {
            // 中央目录头: sig(4) + verMade(2) + verNeed(2) + flags(2) + method(2)
            // + time(2) + date(2) + crc(4) + csize(4) + usize(4) + nlen(2)
            // + xlen(2) + clen(2) + disk(2) + iattr(2) + eattr(4) + loff(4)
            guard readUInt32(bytes, pos) == 0x02014b50 else {
                pos += 1
                continue
            }
            let flags = readUInt16(bytes, pos + 8)
            let method = readUInt16(bytes, pos + 10)
            var csize = UInt64(readUInt32(bytes, pos + 20))
            var usize = UInt64(readUInt32(bytes, pos + 24))
            let nameLength = Int(readUInt16(bytes, pos + 28))
            let extraLength = Int(readUInt16(bytes, pos + 30))
            let commentLength = Int(readUInt16(bytes, pos + 32))
            var localOffset = UInt64(readUInt32(bytes, pos + 42))

            let nameStart = pos + 46
            guard nameStart + nameLength <= bytes.count else { break }
            let nameData = Data(bytes[nameStart..<(nameStart + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8),
                  name.hasPrefix("kernelcache.release") else {
                pos += 46 + nameLength + extraLength + commentLength
                continue
            }

            // ZIP64 extra（id=0x0001）：usize/csize/loff 按需各 8 字节
            let extraStart = nameStart + nameLength
            let extraData = Array(bytes[extraStart..<(extraStart + extraLength)])
            if usize == 0xFFFFFFFF || csize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                var epos = 0
                while epos + 4 <= extraData.count {
                    let eid = readUInt16(extraData, epos)
                    let esize = Int(readUInt16(extraData, epos + 2))
                    if eid == 0x0001 {
                        var o = epos + 4
                        if usize == 0xFFFFFFFF, o + 8 <= extraData.count {
                            usize = readUInt64(extraData, o); o += 8
                        }
                        if csize == 0xFFFFFFFF, o + 8 <= extraData.count {
                            csize = readUInt64(extraData, o); o += 8
                        }
                        if localOffset == 0xFFFFFFFF, o + 8 <= extraData.count {
                            localOffset = readUInt64(extraData, o); o += 8
                        }
                    }
                    epos += 4 + esize
                }
            }

            return ZipEntry(name: name,
                            compressedSize: Int(csize),
                            uncompressedSize: Int(usize),
                            localHeaderOffset: Int(localOffset),
                            nameLength: nameLength,
                            extraLength: extraLength,
                            method: method,
                            flags: flags)
        }
        return nil
    }

    // MARK: - 网络 / 解压工具

    /// Range 请求：拉取指定字节区间。
    private func fetchRange(url: URL, range: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes", forHTTPHeaderField: "Accept-Ranges")
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw makeError("Range 请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return data
    }

    /// raw deflate 解压（zip method 8，无 zlib 头）。
    private func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize < 512 * 1024 * 1024 else { return nil }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { outBuffer -> Int in
            guard let outPtr = outBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            let result = data.withUnsafeBytes { inBuffer -> Int in
                guard let inPtr = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outPtr, expectedSize,
                    inPtr, data.count,
                    nil, COMPRESSION_RAW_DEFLATE
                )
            }
            return result
        }
        guard decoded == expectedSize else { return nil }
        return output
    }

    // MARK: - 已下载列表

    /// 列出已下载的 kernelcache 文件。
    func savedFiles() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: Self.saveDirectory) else { return [] }
        return items.filter { $0.hasPrefix("kernelcache") }.sorted()
    }

    /// 删除已下载文件。
    func deleteSavedFile(named name: String) {
        let path = URL(fileURLWithPath: Self.saveDirectory).appendingPathComponent(name).path
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - 小工具

    private struct ZipEntry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let nameLength: Int
        let extraLength: Int
        let method: UInt16
        let flags: UInt16
    }

    private func readUInt16(_ data: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private func readUInt64(_ data: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (i * 8)
        }
        return value
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data)
        return readUInt32(bytes, offset)
    }

    private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        let bytes = [UInt8](data)
        return readUInt64(bytes, offset)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "KernelCache", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
