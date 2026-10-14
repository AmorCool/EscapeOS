import AirliftFFI
import Darwin
import Foundation

/// Airlift 传输层错误.
///
/// 与 AirBeep 的 `CallRecordingToneError` **刻意解耦**：本仓 `CallRecordingToneService`
/// 有自己的 `ToneError`，由它负责把本错误映射过去。这样传输层不依赖任何业务类型.
enum AirliftTransportError: Error, LocalizedError, Sendable {
    /// 本 build 缺少 AirliftFFI 的读文件符号（补丁未生效 / 库未链接）.
    case unavailable
    /// 未导入配对文件（或配对文件为空）.
    case pairingRequired
    /// airlift 返回非 0，附原生错误信息.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "本 build 缺少 AirLift 文件访问支持."
        case .pairingRequired:
            return "请先导入配对文件并连接 LocalDevVPN，再修改通话录音提示音."
        case .failed(let reason):
            return "AirLift 操作失败：\(reason)"
        }
    }
}

/// `RTLD_DEFAULT` 是 C 宏（`((void *) -2)`），Swift 无法从 iOS SDK 导入
/// （`dlfcn.h` 报 "structure not supported"）。其值平台稳定且有据可查，
/// 故按需构造等价值。全局常量会被严格并发判为非 Sendable，因此改为工厂函数.
private func rtlDefaultHandle() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: -2)
}

/// 一个待写入的提示音文件（名字 + 内容）.
struct AirliftToneFile: Sendable {
    let name: String
    let data: Data
}

/// 串行化**阻塞式** AirLift 调用，并把文件协议细节挡在 SwiftUI 层之外。
/// 沙盒逃逸仍由原生库完成；本类型只提供文件字节并跨 C 边界搬运.
///
/// ## 移植说明（对齐 AirBeep 的 `AirliftToneTransport`）
/// · 读：`al_exploit_read_file`（补丁新增，经 `dlsym` 解析 —— 与 AirBeep 同款，
///   对「头文件是否声明该符号」不敏感）.
/// · 写：`al_exploit_write_dir`（基础库自带，直接经 `AirliftFFI` 模块调用）.
/// · 目标主机：AirBeep 写死 `10.7.0.1`；本仓改为读 `LocalDevVPN.targetIP`
///   （与本仓 AFC / RSD 隧道同一来源，见 `LocalDevVPN` 的解析优先级）.
/// · 目标目录：AirBeep 写死通话提示音目录；本仓改为**入参**，供通用文件接口复用.
///
/// ## 与 AirBeep 的一处**有意**差异（并发）
/// AirBeep 把阻塞调用丢到 `DispatchQueue.global()`，再在 `await` 处挂起 actor ——
/// 由于挂起期间 actor 可重入，**两次调用仍会并发跑**（actor 并未真正串行化）。
/// 本仓对齐「RSD 隧道并发铁律」（同 hostname 并发建隧道会互相抢占），改用**专用串行队列**
/// 让「串行化」名副其实；同时 `al_set_target_host` 写的是 Rust 侧进程级全局，
/// 并发调用会互相踩，串行是正确性要求而非保守选择.
actor AirliftToneTransport {
    static let shared = AirliftToneTransport()

    /// 专用串行队列：所有阻塞式 AirLift 调用都在这条队列上排队执行.
    private static let queue = DispatchQueue(
        label: "com.ipaside.tequiladash.airlift",
        qos: .userInitiated
    )

    private typealias ExploitReadFileFn = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    private typealias BytesFreeFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    private typealias SetTargetFn = @convention(c) (UnsafePointer<CChar>?) -> Int32

    /// 读一个设备上的绝对路径.
    func read(path: String, pairingPath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let data = try Self.readSync(path: path, pairingPath: pairingPath)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 把若干文件**写入**设备上的目标目录.
    func write(files: [AirliftToneFile], directory: String, pairingPath: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    try Self.writeSync(files: files, directory: directory, pairingPath: pairingPath)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 同步实现（在后台队列上执行）

    private static func readSync(path: String, pairingPath: String) throws -> Data {
        configureTargets()

        guard let symbol = dlsym(rtlDefaultHandle(), "al_exploit_read_file") else {
            throw AirliftTransportError.unavailable
        }
        let readFile = unsafeBitCast(symbol, to: ExploitReadFileFn.self)

        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            path.withCString { pathCString in
                readFile(
                    pairingCString,
                    pathCString,
                    AirliftLog.ffiCallback,
                    nil,
                    &output,
                    &outputLength,
                    &outputError
                )
            }
        }

        let message = outputError.map { String(cString: $0) }
        if let outputError {
            al_string_free(outputError)
        }

        guard result == 0 else {
            throw AirliftTransportError.failed(message ?? "AirLift 读取失败（\(result)）")
        }
        guard let output else {
            throw AirliftTransportError.failed("AirLift 未返回 \(path) 的数据")
        }
        defer { freeBytes(output, length: outputLength) }
        return Data(bytes: output, count: outputLength)
    }

    private static func writeSync(files: [AirliftToneFile], directory: String, pairingPath: String) throws {
        configureTargets()

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "TequilaDash-Airlift-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        for file in files {
            try file.data.write(
                to: stagingDirectory.appending(path: file.name),
                options: .atomic
            )
        }

        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            stagingDirectory.path.withCString { sourceCString in
                directory.withCString { targetCString in
                    al_exploit_write_dir(
                        pairingCString,
                        sourceCString,
                        targetCString,
                        AirliftLog.ffiCallback,
                        nil,
                        &outputError
                    )
                }
            }
        }

        let message = outputError.map { String(cString: $0) }
        if let outputError {
            al_string_free(outputError)
        }

        guard result == 0 else {
            throw AirliftTransportError.failed(message ?? "AirLift 写入失败（\(result)）")
        }
    }

    /// 把 airlift 的目标主机设为**本仓当前隧道对端**（不再是 AirBeep 写死的 10.7.0.1）.
    private static func configureTargets() {
        guard let symbol = dlsym(rtlDefaultHandle(), "al_set_target_host") else { return }
        let setTarget = unsafeBitCast(symbol, to: SetTargetFn.self)
        _ = LocalDevVPN.targetIP.withCString { setTarget($0) }
    }

    private static func freeBytes(_ pointer: UnsafeMutablePointer<UInt8>, length: Int) {
        guard let symbol = dlsym(rtlDefaultHandle(), "al_bytes_free") else { return }
        let freeBytes = unsafeBitCast(symbol, to: BytesFreeFn.self)
        freeBytes(pointer, length)
    }
}
