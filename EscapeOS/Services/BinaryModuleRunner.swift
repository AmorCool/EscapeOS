//
//  BinaryModuleRunner.swift
//  EscapeSpace
//
//  二进制模块运行器（v0.3.66）——模块规范 v1.1 "binary" 类型：
//   - 模块 zip 内带 iOS arm64 可执行文件（bin/<name>）
//   - 导入/启用/应用启动时自动后台拉起（autoStart），无需手动点击
//   - posix_spawn 启动、stdout/stderr 重定向到模块日志、kill 停止
//   - WebUI 模块（如 alist）暴露 http://127.0.0.1:<port> 入口
//
//  注意：原生机型受代码签名限制，需 ldid 伪签名的 arm64 二进制；
//  LC 环境下通常可直接运行.启动失败会以模块卡片错误形式反馈.
//
import Foundation
import UIKit
@MainActor
final class BinaryModuleRunner: ObservableObject {
    static let shared = BinaryModuleRunner()
    /// v0.3.141：用户态加载器禁用开关 —— 本环境（LC/iOS 26+）手动映射的代码页
    /// 执行时必被 AMFI 终止（真机两次闪退实锤：真证书签名失败 → uloader 映射
    /// "成功" → 调 OpenListMain → 几秒后闪退）.签名链路修好后走 dlopen，此路径
    /// 只剩必崩价值；代码保留仅为回滚能力.
    nonisolated static let uloaderEnabled = false
    /// 运行中的二进制模块：模块 id → pid（-2 = 进程内 dylib 模式）
    @Published private(set) var runningProcesses: [String: pid_t] = [:]
    /// 启动错误（模块 id → 信息）
    @Published private(set) var startErrors: [String: String] = [:]
    /// 进程内 dylib 模式的模块 id（无独立 pid，随宿主退出）
    @Published private(set) var inProcessModules: Set<String> = []
    private init() {}
    // MARK: 生命周期
    /// 应用启动 / 模块导入 / 启用后调用：拉起所有声明 autoStart 的已启用二进制模块
    func autoStartAll() {
        for module in ModuleService.shared.listModules() {
            guard ModuleService.shared.isEnabled(id: module.id),
                  let bin = module.binary,
                  bin.autoStart == true else { continue }
            start(module: module)
        }
    }
    /// 启动模块二进制（全程后台：Go runtime 初始化 + 服务启动可能数秒，绝不占主线程）
    /// 方案 A：模块入口符号已静态链接进宿主 app（与 Sap* 共用单一 Go
    /// runtime，sap.h 直接暴露给 Swift）.进程内直接调用——无 dylib、无第二 runtime、
    /// 无 AMFI exec 限制.此前 dlopen 第二 Go runtime 的方案在初始化即崩（run.log 实锤）.
    /// automatic=true 为自启动（受崩溃循环守卫保护）；false 为用户手动点启动（总是重试）
    func start(module: EscapeModule, automatic: Bool = true) {
        guard let bin = module.binary else { return }
        guard runningProcesses[module.id] == nil else { return }
        // 崩溃循环守卫：若上一次启动后宿主没活到清除标记（8s），判定崩溃 → 跳过自启动，
        // 保证用户还能进 App 看日志/关模块（否则每次进入 2s 后必崩，永远改不回来）
        let flag = Self.inFlightKey(module.id)
        if automatic && UserDefaults.standard.bool(forKey: flag) {
            let msg = "上次启动疑似导致崩溃，已跳过自动启动（查看日志后可手动启动）"
            appendLog(
                ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log"),
                "[host] \(msg)")
            setError(module.id, msg)
            return
        }
        UserDefaults.standard.set(true, forKey: flag)
        let dataDir = ModuleService.shared.dataURL(for: module.id)
        let logFile = ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log")
        // 撑过 8s 视为启动成功，清除崩溃标记
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            UserDefaults.standard.set(false, forKey: flag)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.runBinaryModule(module, bin: bin, dataDir: dataDir, logFile: logFile)
        }
    }
    /// 通用入口发现：扫描模块 dylib 的符号表，找第一个 "*Main" 结尾的已定义符号.
    /// 这样引擎不需要知道任何模块的符号名（v0.3.112：彻底消除模块名硬编码）.
    nonisolated static func discoverEntrySymbol(moduleDir: URL, logFile: URL) -> String? {
        guard let dylib = findDylib(moduleDir: moduleDir) else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = uloader_symbols_with_suffix(dylib.path, "Main", &buf, Int32(buf.count))
        guard n > 0 else { return nil }
        let names = String(cString: buf).split(separator: "\n").map(String.init)
        // 去掉 Mach-O 前导下划线后交给 dlsym 验证
        for var nm in names {
            if nm.hasPrefix("_") { nm.removeFirst() }
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), nm) {
                _ = sym
                return nm
            }
        }
        return names.first.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
    }
    private static func inFlightKey(_ id: String) -> String { "Binary.startInFlight.\(id)" }
    /// 后台执行体（非隔离：Go 启动全在这里，状态写回走主线程）
    nonisolated private func runBinaryModule(
        _ module: EscapeModule, bin: BinaryConfig,
        dataDir: URL, logFile: URL
    ) {
        // 端口预检：端口被占时绝不调 Go——进程内任何 os.Exit 都会连宿主一起杀
        if let port = bin.port, isPortInUse(UInt16(port)) {
            appendLog(logFile, "[host] 端口 \(port) 已被占用，放弃启动（服务可能已在运行）")
            setError(module.id, "端口 \(port) 已被占用——服务可能已在运行")
            return
        }
        // 数据目录可写性门禁（v0.3.74 闪退根修）：
        // 模块 bootstrap 在目录不可写时走 log.Fatalf → os.Exit → 连宿主一起杀.
        // 这里先建目录 + 写探针，失败就放弃启动并把原因报给 UI（宿主永不死）.
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let probe = dataDir.appendingPathComponent(".write-probe")
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            let msg = "数据目录不可写：\(error.localizedDescription)（LiveContainer 24h 磁盘写入配额可能已满——等待重置或重启设备）"
            appendLog(logFile, "[host] \(msg)；放弃启动以避免 os.Exit 杀宿主")
            setError(module.id, msg)
            return
        }
        do {
            // v0.3.112：入口符号通用化——优先 module.json 的 binary.entrySymbol，
            // 否则自动扫描 dylib 符号表里 "*Main" 结尾的导出（引擎零模块耦合）
            let entrySymbol = bin.entrySymbol
                ?? (Self.discoverEntrySymbol(moduleDir: ModuleService.shared.installURL(for: module.id), logFile: logFile) ?? "Main")
            try startBinaryModule(moduleId: module.id, entrySymbol: entrySymbol,
                                  dataDir: dataDir, logFile: logFile,
                                  moduleDir: ModuleService.shared.installURL(for: module.id))
            appendLog(logFile, "[host] 进程内启动成功（随宿主退出）")
            setRunningInProcess(module.id)
        } catch {
            appendLog(logFile, "[host] 进程内启动失败: \(error.localizedDescription)")
            setError(module.id, "启动失败: \(error.localizedDescription)")
        }
    }
    /// 停止模块（外部进程型 SIGKILL）.
    /// 进程内常驻模块不在此停止：由模块通过 actions 声明桥接停止符号（type=bridge），
    /// 宿主只提供执行接口，语义完全由模块决定.
    func stop(module: EscapeModule) {
        guard let pid = runningProcesses[module.id] else { return }
        guard pid > 0 else {
            print("[Binary][\(module.id)] 进程内常驻模块不在此停止（走模块 actions 的桥接符号）")
            return
        }
        kill(pid, SIGKILL)
        runningProcesses[module.id] = nil
        print("[Binary][\(module.id)] 已停止 pid=\(pid)")
    }

    /// v0.3.159：通用桥调用——按 action 声明解析实参并调用模块导出符号.
    /// 符号签名按 args 数量分派：0 → fn()；1 → fn(a)；2 → fn(a, b)（C.int 返回）.
    /// 参数来源（args 元素）：randomPassword=生成 8 位随机密码（去易混淆字符），
    /// dataDir=模块数据目录路径，moduleDir=模块安装目录路径，"str:xxx"=字面量.
    /// 返回 (rc, 实参数组)——消息模板由调用方组装.
    nonisolated static func bridgeCall(module: EscapeModule, symbol: String, argSpecs: [String]) throws -> (Int32, [String]) {
        guard let sym = resolveBridgeSymbol(symbol) else {
            throw BinaryModuleError.spawnFailed("模块未导出 \(symbol)（需更新模块至支持版本）")
        }
        var actual: [String] = []
        for spec in argSpecs {
            switch spec {
            case "randomPassword":
                actual.append(randomPassword(8))
            case "dataDir":
                actual.append(ModuleService.shared.dataURL(for: module.id).path)
            case "moduleDir":
                actual.append(ModuleService.shared.installURL(for: module.id).path)
            default:
                actual.append(spec.hasPrefix("str:") ? String(spec.dropFirst(4)) : spec)
            }
        }
        var rc: Int32 = -99
        switch actual.count {
        case 0:
            typealias Fn0 = @convention(c) () -> Int32
            rc = unsafeBitCast(sym, to: Fn0.self)()
        case 1:
            let a = strdup(actual[0])
            defer { free(a) }
            typealias Fn1 = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
            rc = unsafeBitCast(sym, to: Fn1.self)(a)
        default:
            let a = strdup(actual[0])
            let b = strdup(actual[1])
            defer { free(a); free(b) }
            typealias Fn2 = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32
            rc = unsafeBitCast(sym, to: Fn2.self)(a, b)
        }
        return (rc, actual)
    }
    /// 随机密码（8 位，去除易混淆字符 0O1lI）
    nonisolated static func randomPassword(_ len: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<len).map { _ in chars.randomElement()! })
    }
    /// 运行状态查询
    func isRunning(module: EscapeModule) -> Bool {
        if inProcessModules.contains(module.id) { return true }
        guard let pid = runningProcesses[module.id], pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
    /// WebUI 地址（binary.port + webPath）
    func webURL(for module: EscapeModule) -> URL? {
        guard let bin = module.binary, let port = bin.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(bin.webPath ?? "/")")
    }
    /// 打开 WebUI（浏览器）
    func openWebUI(module: EscapeModule) {
        guard let url = webURL(for: module) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIApplication.shared.open(url)
        }
    }
// MARK: 进程内启动（方案 A：单一 Go runtime，v0.3.73）
    /// 启动二进制模块（双形态统一入口）：
    /// ① 模块目录带 bin/*.dylib（可拆卸 zip 安装）→ dlopen + dlsym
    /// ② 否则 RTLD_DEFAULT 找内置静态符号（openlist_embed 构建形态）
    /// ③ 都没有 → 报错提示安装模块 zip
    /// 数据目录一律以**参数**传给 Go（Go env 在 runtime 初始化时已快照，setenv 事后不可见）；
    /// fd 2 重定向到 data/go_stderr.log 抓 Go runtime 临终输出；8MB 大栈 pthread 承载入口.
    /// 常驻保存用户态加载的镜像句柄（不卸载：Go runtime 必须存活）
    private static let uloaderLock = NSLock()
    private nonisolated(unsafe) static var cachedUloaderImage: UnsafeMutableRawPointer?
    nonisolated private static func cacheUloaderImage(_ img: UnsafeMutableRawPointer) {
        uloaderLock.lock(); defer { uloaderLock.unlock() }
        cachedUloaderImage = img
    }
    nonisolated private func startBinaryModule(moduleId: String, entrySymbol: String,
                                          dataDir: URL, logFile: URL, moduleDir: URL) throws {
        // fd 2 重定向：Go runtime 初始化阶段的 throw/fatal（先于任何 Go 代码）原本只写
        // 进程 stderr，LC 下直接丢失——重定向到文件后 SSH `mlog go_stderr.log` 可见.
        let goErr = dataDir.appendingPathComponent("go_stderr.log")
        let fd = open(goErr.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            dup2(fd, STDERR_FILENO)
            close(fd)
        }
        uloader_install_crash_probe(STDERR_FILENO)   // v0.3.120：硬故障诊断落盘
        appendLog(logFile, "[host] 调用 \(entrySymbol)（\(moduleId)模块，进程内）")
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        appendLog(logFile, "[App \(appVer)] 当前内存足迹 \(Self.currentFootprintMB())MB")
        var sym: UnsafeMutableRawPointer?
        var dylibName: String?
        var reSignErrorText: String?
        var uloaderErrorText: String?
        // ① 可拆卸 dylib 模块（zip 安装，bin/*.dylib）
        if let dylibURL = Self.findDylib(moduleDir: moduleDir) {
            var handle: UnsafeMutableRawPointer?
            if let h = dlopen(dylibURL.path, RTLD_NOW | RTLD_GLOBAL) {
                handle = h
            } else {
                // v0.3.119：dlopen 必被 dyld 库校验拒绝（LC 同环境实测：ldid/zsign
                // 签名都报 code signature invalid）→ 直接走用户态加载器（匿名内存
                // 方案，无需有效签名——见 uloader.c 注释）.重签步骤已删.
                reSignErrorText = dlerror().map { String(cString: $0) } ?? "未知错误"
                appendLog(logFile, "[host] dlopen 失败（\(reSignErrorText!.suffix(500))）→ 用户态加载器")
                appendLog(logFile, "[host] dlopen#1 目标(原始): \(dylibURL.path)")
                Self.appendDiag(logFile, "\n=== dlopen#1 失败(原始 \(dylibURL.lastPathComponent)) ===\n\(reSignErrorText!)\n")
            }
            if let handle {
                sym = dlsym(handle, entrySymbol)
                if sym != nil {
                    dylibName = dylibURL.lastPathComponent
                    Self.cacheBinaryModuleHandle(handle)   // 故意不 dlclose：Go runtime 必须常驻
                    appendLog(logFile, "[host] 已加载可拆卸模块 dylib: \(dylibURL.lastPathComponent)")
                } else {
                    appendLog(logFile, "[host] dylib 缺少 \(entrySymbol) 导出")
                }
            } else {
            // v0.3.122：真证书路径（SideStore 信任链）——有开发证书时先签后 dlopen。
            // 真证书与 App 同 TeamID → 库验证通过 → 文件映射有效（本环境唯一活路）。
            // v0.3.161：无本地证书时自动恢复——已登录 Apple ID 则自动签发
            // （Apple 异步签发，createCertificate 内部轮询），失败再走失败分支。
            if !DeveloperCertStore.shared.hasCert {
                appendLog(logFile, "[host] 本地无签名证书 → 尝试自动签发（需已登录 Apple ID）")
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var certOK = false
                Task.detached(priority: .userInitiated) {
                    certOK = await Self.ensureCertAvailable(logFile: logFile)
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 60)
                if certOK {
                    appendLog(logFile, "[host] 证书自动签发完成")
                }
            }
            if DeveloperCertStore.shared.hasCert, DeveloperCertStore.shared.jitFreeMode {
                    appendLog(logFile, "[host] 开发证书可用 → 真证书签名")
                    let signDbg = logFile.deletingLastPathComponent()
                        .appendingPathComponent("data").appendingPathComponent("go_sign_debug.log")
                    // v0.3.143: 就地签名原始文件（内核实锤 code signature invalid errno=1，
                    // 疑点集中在 rebuildToNewFile 产物——其已签输出曾连 zsign 自身都解析失败）.
                    // 就地失败再退回 rebuild 副本路径.
                    var signURL = dylibURL
                    var signOk = DeveloperCertStore.shared.signDylib(path: signURL.path, bundleId: moduleId, debugLog: signDbg, useMainIdent: true)
                    if !signOk {
                        appendLog(logFile, "[host] 就地签名失败 → 退回 rebuild 副本路径")
                        signURL = (try? MachoReSign.rebuildToNewFile(at: dylibURL, bundleId: moduleId)) ?? dylibURL
                        signOk = DeveloperCertStore.shared.signDylib(path: signURL.path, bundleId: moduleId, debugLog: signDbg, useMainIdent: true)
                    }
                    if signOk {
                        appendLog(logFile, "[host] 真证书签名完成: \(signURL.lastPathComponent)")
                        if let h = dlopen(signURL.path, RTLD_NOW | RTLD_GLOBAL) {
                            handle = h
                            appendLog(logFile, "[host] 真证书签名后 dlopen 成功 ✓")
                        } else {
                            let e2 = dlerror().map { String(cString: $0) } ?? "未知错误"
                            appendLog(logFile, "[host] 真证书签名后 dlopen 仍失败: \(e2.suffix(500))")
                            appendLog(logFile, "[host] dlopen#2 目标(签名后): \(signURL.path)")
                            Self.appendDiag(logFile, "\n=== dlopen#2 失败(签名后 \(signURL.lastPathComponent)) ===\n\(e2)\n")
                        }
                    } else {
                        appendLog(logFile, "[host] 真证书签名失败（证书/私钥不可用）")
                    }
                }
                if handle == nil, !Self.uloaderEnabled {
                    // v0.3.141：必崩兜底已封 —— 给明确指引代替闪退
                    uloaderErrorText = "模块无法安全加载: dlopen 被系统拒绝且真证书签名失败. 请确认已登录 Apple ID（启动时会自动签发证书）或到「更多 → 证书管理」导入 p12"
                    appendLog(logFile, "[host] 用户态加载器已禁用(v0.3.141): \(uloaderErrorText!)")
                }
                if handle == nil, Self.uloaderEnabled {
                // v0.3.108：dlopen 被 dyld 库校验拦下（ad-hoc 无 CMS blob 在 dyld 层必拒）→
                // 改用自研用户态 Mach-O 加载器（移植自 Nyxian kxld）：自己 mmap + rebase + bind，
                // 完全绕开 dyld——这是 LC / Nyxian 加载访客代码的方式.
                let target = dylibURL
                var errBuf = [CChar](repeating: 0, count: 512)
                if let img = uloader_load(target.path, &errBuf, errBuf.count) {
                    appendLog(logFile, "[host] 用户态加载器映射成功：\(target.lastPathComponent)")
                    let s = uloader_symbol(img, entrySymbol)
                    if let s {
                        sym = s
                        dylibName = target.lastPathComponent
                        Self.cacheUloaderImage(img)   // 常驻，不卸载（Go runtime）
                        appendLog(logFile, "[host] 用户态加载器解析 \(entrySymbol) 成功 ✓")
                    } else {
                        uloaderErrorText = "映射成功但未找到 \(entrySymbol)（符号表可能仅 trie）"
                    appendLog(logFile, "[host] 用户态加载器未找到 \(entrySymbol)（符号表可能仅 trie）")
                    }
                } else {
                    let reason = String(cString: errBuf)
                    uloaderErrorText = reason
                    appendLog(logFile, "[host] 用户态加载器失败: \(reason)")
                }
                }   // v0.3.122 handle==nil 守卫闭合
            }
        }
        // ② 内置静态符号（openlist_embed 构建形态）；RTLD_DEFAULT = -2
        if sym == nil {
            sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), entrySymbol)
            if sym != nil {
                appendLog(logFile, "[host] 使用内置静态 \(entrySymbol)")
            }
        }
        guard let fnSym = sym else {
            // v0.3.110：文案改为**动态报真实原因**（旧文案静态枚举"未内置/无 dylib"，
            // 而实际 dylib 就在模块目录里、是加载被拒——误导排查方向）
            var parts: [String] = []
            if let dylibURL = Self.findDylib(moduleDir: moduleDir) {
                parts.append("已找到模块 dylib：\(dylibURL.lastPathComponent)")
                if let e = reSignErrorText {
                    parts.append("dyld 加载被拒（dlopen）：\(e.suffix(400))")
                }
                if let e = uloaderErrorText {
                    parts.append("用户态加载器失败：\(e)")
                }
                if reSignErrorText == nil, uloaderErrorText == nil {
                    parts.append("（未记录具体失败原因，见 run.log）")
                }
            } else {
                parts.append("模块目录中无 bin/*.dylib——请从 module-esc edge 导入 com.escapeos.alist 模块 zip")
            }
            parts.append("本 App 未内置 \(moduleId) 的 \(entrySymbol)，外部导入属正常现象")
            throw BinaryModuleError.spawnFailed(parts.joined(separator: "\n"))
        }
        // 数据目录以 strdup C 字符串 + 函数符号一起打包成线程上下文
        guard let dirC = strdup(dataDir.path) else {
            throw BinaryModuleError.spawnFailed("strdup 数据目录路径失败")
        }
        let ctx = BinaryModuleLaunchCtx(sym: fnSym, dir: dirC)
        appendLog(logFile, "[host] 调用 \(entrySymbol)\(dylibName.map { "（dylib: \($0)）" } ?? "（内置）")")
        var attr = pthread_attr_t()
        guard pthread_attr_init(&attr) == 0 else {
            throw BinaryModuleError.spawnFailed("pthread_attr_init 失败")
        }
        pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)
        var tid: pthread_t?
        let rc = pthread_create(&tid, &attr, openlistEntry, Unmanaged.passRetained(ctx).toOpaque())
        pthread_attr_destroy(&attr)
        guard rc == 0 else {
            throw BinaryModuleError.spawnFailed("pthread_create 失败：\(rc)")
        }
    }
    /// v0.3.161：确保证书可用——无本地证书且 Apple ID 已登录时自动签发
    /// （createCertificateWithStoredAccount 内部含异步签发轮询）。返回最终是否有证书.
    nonisolated private static func ensureCertAvailable(logFile: URL) async -> Bool {
        let store = DeveloperCertStore.shared
        if store.hasCert { return true }
        do {
            try await store.createCertificateWithStoredAccount()
        } catch {
            Self.note(logFile, "自动签发失败: \(error.localizedDescription)")
        }
        if store.hasCert {
            Self.note(logFile, "自动签发成功，本地证书已就绪")
        }
        return store.hasCert
    }
    /// static 上下文的 run.log 追加（与实例 appendLog 同格式）
    nonisolated private static func note(_ logFile: URL, _ line: String) {
        let text = "[\(DateFormatter.now())][\(DateFormatter.logStamp)] [host] \(line)
"
        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); try? fh.close()
        } else {
            try? text.data(using: .utf8)?.write(to: logFile)
        }
    }
    /// 查找模块目录下 bin/*.dylib（可拆卸模块形态）
    nonisolated static func findDylib(moduleDir: URL) -> URL? {
        let binDir = moduleDir.appendingPathComponent("bin", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: binDir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { $0.pathExtension.lowercased() == "dylib" }
    }
    /// dylib 句柄缓存（SSH 诊断命令复用；故意不 dlclose——Go runtime 必须常驻）
    /// nonisolated(unsafe)：@MainActor 类的存储属性不能直接 nonisolated；
    /// 访问全部经由 handleLock 保护的存取器，实际无竞争.
    nonisolated(unsafe) private static var cachedBinaryModuleHandle: UnsafeMutableRawPointer?
    private static let handleLock = NSLock()
    nonisolated private static func cacheBinaryModuleHandle(_ h: UnsafeMutableRawPointer) {
        handleLock.lock()
        if cachedBinaryModuleHandle == nil { cachedBinaryModuleHandle = h }
        handleLock.unlock()
    }
    /// v0.3.158：解析进程内模块的桥接导出符号（停止/重置密码等）
    /// 优先已加载 dylib 句柄 → 内置静态（RTLD_DEFAULT）.
    nonisolated static func resolveBridgeSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        handleLock.lock()
        let h = cachedBinaryModuleHandle
        handleLock.unlock()
        if let h, let s = dlsym(h, name) { return s }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
    /// 供 SSH 诊断命令解析任意二进制模块的导出符号：优先已加载 dylib → 模块目录 dylib → 内置静态
    nonisolated static func resolveBinaryModuleSymbol(_ name: String, moduleDir: URL, moduleId: String) -> UnsafeMutableRawPointer? {
        let logFile = moduleDir.appendingPathComponent("run.log")
        func note(_ line: String) {
            // 便于诊断：解析失败原因直接落模块的 run.log（卡片「日志」按钮可见）
            let text = "[\(DateFormatter.now())][\(DateFormatter.logStamp)] [resolve] \(line)\n"
            if let fh = FileHandle(forWritingAtPath: logFile.path) {
                fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); try? fh.close()
            } else {
                try? text.data(using: .utf8)?.write(to: logFile)
            }
        }
        if let h = cachedBinaryModuleHandle, let s = dlsym(h, name) { return s }
        if let dylib = findDylib(moduleDir: moduleDir) {
            if let h = dlopen(dylib.path, RTLD_NOW | RTLD_GLOBAL) {
                cacheBinaryModuleHandle(h)
                if let s = dlsym(h, name) { return s }
                note("dlopen 成功但无符号 \(name)")
            } else {
                // v0.3.115：dlopen 被 dyld 库校验拒绝 → 走自研用户态加载器（绕开 dyld）
                let err0 = dlerror().map { String(cString: $0) } ?? "?"
                note("dlopen 失败：\(err0.suffix(400))")
                Self.appendDiag(logFile, "\n=== [ext] dlopen#1 失败 ===\n\(err0)\n")
                // v0.3.122：真证书路径（SideStore 信任链）
                if DeveloperCertStore.shared.hasCert, DeveloperCertStore.shared.jitFreeMode {
                    note("开发证书可用 → 真证书签名")
                    let signDbg = logFile.deletingLastPathComponent()
                        .appendingPathComponent("data").appendingPathComponent("go_sign_debug.log")
                    // v0.3.143: 就地签名原始文件，失败退回 rebuild 副本（同 startBinaryModule）
                    var signURL = dylib
                    var signOk = DeveloperCertStore.shared.signDylib(path: signURL.path, bundleId: moduleId, debugLog: signDbg, useMainIdent: true)
                    if !signOk {
                        note("就地签名失败 → 退回 rebuild 副本路径")
                        signURL = (try? MachoReSign.rebuildToNewFile(at: dylib, bundleId: moduleId)) ?? dylib
                        signOk = DeveloperCertStore.shared.signDylib(path: signURL.path, bundleId: moduleId, debugLog: signDbg, useMainIdent: true)
                    }
                    if signOk {
                        note("真证书签名完成: \(signURL.lastPathComponent)")
                        if let h = dlopen(signURL.path, RTLD_NOW | RTLD_GLOBAL) {
                            cacheBinaryModuleHandle(h)
                            if let resolved = dlsym(h, name) {
                                note("真证书签名后解析到符号 \(name) ✓")
                                return resolved
                            }
                            note("真证书签名后 dlopen 成功但无符号 \(name)")
                        } else {
                            let e2 = dlerror().map { String(cString: $0) } ?? "?"
                            note("真证书签名后 dlopen 仍失败: \(e2.suffix(400))")
                            Self.appendDiag(logFile, "\n=== [ext] dlopen#2 失败(签名后 \(signURL.lastPathComponent)) ===\n\(e2)\n")
                        }
                    } else {
                        note("真证书签名失败")
                    }
                }
                // v0.3.141：uloader 禁用开关（本环境映射代码页执行必被 AMFI 终止 → 必崩）
                guard Self.uloaderEnabled else {
                    note("用户态加载器已禁用(v0.3.141): dlopen 被拒且真证书签名失败. 请确认已登录 Apple ID（启动时自动签发）或导入 p12")
                    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT：内置静态
                }
                // v0.3.119：匿名内存方案下 uloader 不需要有效签名——直接加载原始文件
                // （v0.3.118 实测：zsign 重签 + 全新 vnode，签名登记仍 EPERM → AMFI
                //  拒的是 blob 本身，重签无意义）
                let target = dylib
                var errBuf = [CChar](repeating: 0, count: 512)
                if let img = uloader_load(target.path, &errBuf, errBuf.count) {
                    note("用户态加载器映射成功（内存足迹 \(currentFootprintMB())MB）")
                    if let s = uloader_symbol(img, name) {
                        cacheUloaderImage(img)
                        note("用户态加载器解析到符号 \(name) ✓")
                        return s
                    }
                    note("用户态加载器未找到符号 \(name)")
                } else {
                    note("用户态加载器失败：\(String(cString: errBuf))")
                }
            }
        }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT：内置静态
    }
    /// 当前进程物理足迹（MB）——诊断 Jetsam 内存杀（匿名代码段无法换出，全常驻）
    nonisolated static func currentFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// 端口占用检测（本机回环，connect 立即返回）
    nonisolated private func isPortInUse(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }
    /// 追加宿主侧日志到模块 run.log（与子进程 stdout/stderr 同文件）
    nonisolated private func appendLog(_ logFile: URL, _ line: String) {
        let text = "[\(DateFormatter.now())][\(DateFormatter.logStamp)] \(line)\n"
        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.data(using: .utf8)!.write(to: logFile)
        }
    }
    /// 诊断原文追加到 data/go_sign_debug.log（SSH mlog 直读、无行长截断；
    /// run.log/UI 层的 prefix/suffix 截断会吃掉 dyld 报错尾部的真实拒绝原因）
    nonisolated private static func appendDiag(_ logFile: URL, _ text: String) {
        let url = logFile.deletingLastPathComponent()
            .appendingPathComponent("data").appendingPathComponent("go_sign_debug.log")
        if let fh = FileHandle(forWritingAtPath: url.path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.data(using: .utf8)!.write(to: url)
        }
    }
    // MARK: 状态写回（主线程队列）
    nonisolated private func setRunningInProcess(_ id: String) {
        DispatchQueue.main.async {
            self.inProcessModules.insert(id)
            self.runningProcesses[id] = -2
            self.startErrors[id] = nil
            print("[Binary][\(id)] 已进程内启动")
        }
    }
    nonisolated private func setRunningProcess(_ id: String, _ pid: pid_t) {
        DispatchQueue.main.async {
            self.runningProcesses[id] = pid
            self.inProcessModules.remove(id)
            self.startErrors[id] = nil
            print("[Binary][\(id)] 已启动 pid=\(pid)")
        }
    }
    nonisolated private func setError(_ id: String, _ msg: String) {
        DispatchQueue.main.async {
            self.startErrors[id] = msg
            print("[Binary][\(id)] \(msg)")
        }
    }
}
private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"   // 时:分:秒.毫秒（用户要求精确到毫秒）
        return f
    }()
    /// 当前时间字符串（HH:mm:ss）
    static func now() -> String { logStamp.string(from: Date()) }
}
// MARK: 通用二进制模块进程入口（C 函数指针，供 pthread_create 使用）
// ctx = strdup 出来的数据目录 C 字符串；线程长期存活（服务阻塞），故不 free.
// 数据目录必须走参数：Go 在 runtime 初始化时已快照 environ，事后 setenv 对
// os.Getenv 不可见（v0.3.78 闪退根因）.
// MARK: 通用二进制模块进程入口（C 函数指针，供 pthread_create 使用）
/// 通用二进制模块入口函数 C 签名（Go: func Main(dataDirC *C.char) C.int）
private typealias BinaryEntryFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
/// pthread 线程上下文：解析好的函数符号 + strdup 的数据目录.
/// 线程长期存活（服务阻塞），ctx 与 dir 均故意不释放.
private final class BinaryModuleLaunchCtx {
    let sym: UnsafeMutableRawPointer
    let dir: UnsafeMutablePointer<CChar>
    init(sym: UnsafeMutableRawPointer, dir: UnsafeMutablePointer<CChar>) {
        self.sym = sym
        self.dir = dir
    }
    func call() -> Int32 {
        let fn = unsafeBitCast(sym, to: BinaryEntryFn.self)
        return fn(dir)
    }
}
private let openlistEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { ctx in
    let c = Unmanaged<BinaryModuleLaunchCtx>.fromOpaque(ctx).takeRetainedValue()
    _ = c.call()   // Go runtime 首次调用时初始化；阻塞服务，永不返回
    return nil
}
enum BinaryModuleError: LocalizedError {
    case spawnFailed(String)
    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return m  // 不加前缀——setError 处统一加
        }
    }
}