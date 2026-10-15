import Foundation
import UIKit

/// 本机 Anisette（ODA）的 C++ 桥接层.
///
/// ## 调用链
/// ```
/// Swift（本文件）
///   -> anisette_core.h 的 C 接口（get_anisette_headers_uc / start_provision_uc / end_provision_uc）
///     -> anisette_core_uc.cpp（ADI 协议编排）
///       -> Loader/elf_loader_emulator.cpp（把 ELF64 AArch64 的 ADI 引擎加载进 Unicorn）
///         -> Unicorn 的 AArch64 解释器（TCI 后端，无需 JIT 权限）
/// ```
///
/// ## 来源
/// C++ 层逐字移植自 **AnisetteKit**（`github.com/mahee96/AnisetteKit`）的 `Native/`：
/// `anisette_core_uc.cpp` + `Loader/elf_loader_emulator.{h,cpp}` + `anisette_base.{h,cpp}`。
/// 用的是**标准 Unicorn API**（`uc_open` / `uc_mem_map` / `uc_emu_start` / `uc_hook_add` …），
/// 与本仓 SAP 用的同一个 `libunicorn.a` 兼容 —— v0.3.613 起该库含 **x86 + aarch64 双后端**
/// （x86 给 SAP 的 Apple Mach-O 资产，aarch64 给本机的 ELF ADI 引擎）。
///
/// ## 许可说明（内部自用，不公开）
/// AnisetteKit 为 AGPLv3。本仓为**内部自用、不公开分发**，
/// 分发类许可不构成约束（判据见 `rules/USER.md`「许可 / 限制 / 自我设限」一节）。
///
/// ## 与远程路径的关系
/// 本文件只负责「本机取数」。是否走本机由 `AnisetteProvider.getAnisetteData` 决定：
/// 开关开 + 引擎就绪 + 有设备身份 ⇒ 走这里；否则显式回退远程并记日志。
enum OnDeviceAnisetteClient {

    // MARK: - 错误

    enum ClientError: LocalizedError {
        /// C 层返回非 0
        case cError(code: Int32, detail: String)
        /// 返回的 JSON 不是预期结构
        case badResponse(String)
        /// 返回值不是合法 UTF-8
        case badEncoding

        var errorDescription: String? {
            switch self {
            case .cError(let code, let detail):
                return "本机 Anisette 失败（\(code)）：\(detail)"
            case .badResponse(let raw):
                return "本机 Anisette 返回结构异常：\(raw.prefix(200))"
            case .badEncoding:
                return "本机 Anisette 返回非 UTF-8"
            }
        }
    }

    // MARK: - 取 headers

    /// 用本机 ADI 引擎产出 anisette headers.
    ///
    /// - Parameters:
    ///   - identifier: 16 字节设备标识（`AnisetteProvider` 的 keychain `identifier`）
    ///   - adiPb: ADI 配给数据（keychain `adiPb` 的原始字节）
    ///   - libDirectory: ADI 引擎两份 `.so` 所在目录
    ///   - provisioningDirectory: 配给数据目录（C 层会在其中落盘会话状态）
    /// - Returns: 与远程路径同型的 `AnisetteData`
    static func headers(identifier: Data,
                        adiPb: Data,
                        libDirectory: URL,
                        provisioningDirectory: URL) throws -> AnisetteData {
        let json = try callC { outJSON in
            identifier.withUnsafeBytes { idBuf in
                adiPb.withUnsafeBytes { pbBuf in
                    get_anisette_headers_uc(
                        libDirectory.path,
                        provisioningDirectory.path,
                        idBuf.bindMemory(to: UInt8.self).baseAddress,
                        pbBuf.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(adiPb.count),
                        outJSON)
                }
            }
        }
        return try parseHeaders(json)
    }

    // MARK: - 配给（首次或 adiPb 过期时用）

    struct ProvisioningStart {
        /// C 层给的会话号，`endProvision` 要用
        let session: UInt32
        /// 原始 JSON（含 spim 等字段，交给上层按需解析）
        let raw: [String: Any]
    }

    /// 开始配给：拿到 `spim`，交给 Apple 的 `midStartProvisioning` 换 `ptm` / `tk`.
    static func startProvision(identifier: Data,
                               spim: Data,
                               libDirectory: URL,
                               provisioningDirectory: URL) throws -> ProvisioningStart {
        let json = try callC { outJSON in
            identifier.withUnsafeBytes { idBuf in
                spim.withUnsafeBytes { spimBuf in
                    start_provision_uc(
                        libDirectory.path,
                        provisioningDirectory.path,
                        idBuf.bindMemory(to: UInt8.self).baseAddress,
                        spimBuf.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(spim.count),
                        outJSON)
                }
            }
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ClientError.badResponse(json)
        }
        // C 层把会话号放在 "session" 字段（AnisetteKit 同款）
        let session: UInt32
        if let n = obj["session"] as? NSNumber {
            session = n.uint32Value
        } else if let s = obj["session"] as? String, let n = UInt32(s) {
            session = n
        } else {
            throw ClientError.badResponse(json)
        }
        return ProvisioningStart(session: session, raw: obj)
    }

    /// 结束配给：把 Apple 回的 `ptm` / `tk` 交给 C 层，产出可长期使用的 `adiPb` 与 headers.
    static func endProvision(identifier: Data,
                             session: UInt32,
                             ptm: Data,
                             tk: Data,
                             libDirectory: URL,
                             provisioningDirectory: URL) throws -> AnisetteData {
        let json = try callC { outJSON in
            identifier.withUnsafeBytes { idBuf in
                ptm.withUnsafeBytes { ptmBuf in
                    tk.withUnsafeBytes { tkBuf in
                        end_provision_uc(
                            libDirectory.path,
                            provisioningDirectory.path,
                            idBuf.bindMemory(to: UInt8.self).baseAddress,
                            session,
                            ptmBuf.bindMemory(to: UInt8.self).baseAddress,
                            UInt32(ptm.count),
                            tkBuf.bindMemory(to: UInt8.self).baseAddress,
                            UInt32(tk.count),
                            outJSON)
                    }
                }
            }
        }
        return try parseHeaders(json)
    }

    /// 取消配给（用户中途放弃 / 切换服务器时清会话状态）.
    static func cancelProvision(identifier: Data,
                                session: UInt32,
                                libDirectory: URL,
                                provisioningDirectory: URL) {
        identifier.withUnsafeBytes { idBuf in
            _ = cancel_provision_uc(
                libDirectory.path,
                provisioningDirectory.path,
                idBuf.bindMemory(to: UInt8.self).baseAddress,
                session)
        }
    }

    // MARK: - C 调用样板

    /// 统一处理「C 接口返回 char* + 错误码」的样板：
    /// 分配 `char*`、调 `body`、非 0 码转错误、UTF-8 解码、**释放 C 字符串**.
    private static func callC(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32) throws -> String {
        var outPtr: UnsafeMutablePointer<CChar>? = nil
        let code = withUnsafeMutablePointer(to: &outPtr) { body($0) }
        defer {
            if let p = outPtr { free_c_string(p) }
        }
        guard code == 0 else {
            let detail: String
            if let p = outPtr, let s = String(validatingUTF8: p) {
                detail = s
            } else if let d = get_anisette_error_description(code) {
                detail = String(cString: d)
            } else {
                detail = "未知错误"
            }
            throw ClientError.cError(code: code, detail: detail)
        }
        guard let p = outPtr else {
            throw ClientError.badResponse("<null>")
        }
        guard let s = String(validatingUTF8: p) else {
            throw ClientError.badEncoding
        }
        return s
    }

    // MARK: - JSON 解析

    /// 把 C 层返回的 JSON 转成 `AnisetteData`.
    ///
    /// C 层输出的键与 Apple 的 anisette header 同型（`X-Apple-I-MD` / `X-Apple-I-MD-M` /
    /// `X-Apple-I-MD-RINFO` / `X-Apple-I-MD-LU`），与远程 `get_headers` 的返回一致 ——
    /// 故这里复用 `AnisetteProvider.extractAnisetteData` 的同一套映射口径。
    /// 同时容忍「已经是 AnisetteData 字段名」的输入（有些实现直接吐内部结构）.
    private static func parseHeaders(_ json: String) throws -> AnisetteData {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ClientError.badResponse(json)
        }

        // 兼容两种键名：Apple header 名 与 内部字段名
        func str(_ keys: [String]) -> String? {
            for k in keys {
                if let v = obj[k] as? String { return v }
                if let n = obj[k] as? NSNumber { return n.stringValue }
            }
            return nil
        }

        guard let machineID = str(["X-Apple-I-MD-M", "machineID"]),
              let otp = str(["X-Apple-I-MD", "oneTimePassword"]),
              let rinfoRaw = str(["X-Apple-I-MD-RINFO", "routingInfo"]),
              let rinfo = UInt64(rinfoRaw) else {
            throw ClientError.badResponse(json)
        }

        let device = UIDeviceLike.current()
        return AnisetteData(
            machineID: machineID,
            oneTimePassword: otp,
            localUserID: str(["X-Apple-I-MD-LU", "localUserID"]) ?? "",
            routingInfo: rinfo,
            deviceUniqueIdentifier: str(["X-Mme-Device-Id", "deviceUniqueIdentifier"]) ?? device.uniqueID,
            deviceSerialNumber: str(["X-Apple-I-SRL-NO", "deviceSerialNumber"]) ?? "0",
            deviceDescription: str(["X-MMe-Client-Info", "deviceDescription"]) ?? device.description,
            date: Date(),
            locale: Locale.current,
            timeZone: TimeZone.current)
    }
}

/// 取设备标识的轻量封装（本文件不直接依赖 UIKit，便于复用与测试）.
private enum UIDeviceLike {
    struct Info {
        let uniqueID: String
        let description: String
    }

    static func current() -> Info {
        // 与 AnisetteProvider 同源：identifierForVendor 作为本机设备唯一标识兜底
        let id = (UIDevice.current.identifierForVendor?.uuidString) ?? UUID().uuidString
        let desc = "<\(UIDevice.current.model)> <iOS;\(UIDevice.current.systemVersion)> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        return Info(uniqueID: id, description: desc)
    }
}
