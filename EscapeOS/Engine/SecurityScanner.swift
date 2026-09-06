import Foundation
import Darwin
import SwiftUI

/// v0.3.200：设备体检引擎 —— 安全检测项执行器。
///
/// 方法论移植自 Lessica/Reveil（内嵌 IOSSecuritySuite）与爱思 SecurityPresets.plist
/// 名单。**适配约束**：本 App 无越狱、运行于 LiveContainer 沙箱 —— Reveil 的
/// "可疑文件路径存在性"清单（126 条系统路径）在沙箱内一律被拦成不存在（假阴性），
/// 故不采用；保留**在沙箱内依然有判定意义**的检测：
///   1. 危险环境变量（SecurityPresets.insecureEnvironmentVariables）
///   2. DYLD 注入库扫描（_dyld_image_count / _dyld_get_image_name）
///   3. 可疑 ObjC 类（SecurityPresets.suspiciousObjCClasses）
///   4. 可疑端口探测（SecurityPresets.suspiciousPorts：Frida 27042 等，本地 socket connect）
///   5. 系统目录可写探测（/ 、/jb/ 、/Library/ 写探针——成功即沙盒异常）
/// 每项三态：passed / warn / failed，附说明。

/// 单项检查结果
struct SecurityCheckResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let passed: Bool
    let warn: Bool
    /// 该检查扣分值（failed 扣分；warn 小扣）
    var penalty: Int {
        passed ? 0 : (warn ? 4 : 12)
    }
    var iconName: String { passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    var color: Color { passed ? .green : (warn ? .yellow : .orange) }
}

/// 体检引擎
enum SecurityScanner {
    /// 全部检查项 id（用于 UI 展示进度）
    static let checkIDs = [
        "env", "dyld", "objc", "ports", "writable",
    ]

    /// 执行全部检查（同步；最耗时项 = 端口探测 5×0.3s ≈ 1.5s）。
    /// 返回 (结果数组, 总分 0-100)
    static func runAll() -> ([SecurityCheckResult], Int) {
        let env = checkEnvironmentVariables()
        let dyld = checkDYLDInjection()
        let objc = checkSuspiciousObjCClasses()
        let ports = checkSuspiciousPorts()
        let writable = checkSystemDirsWritable()
        let results = [env, dyld, objc, ports, writable]
        let total = max(0, 100 - results.reduce(0) { $0 + $1.penalty })
        return (results, total)
    }

    // MARK: 1. 危险环境变量（Presets: insecureEnvironmentVariables）

    /// 危险环境变量名单（SecurityPresets 同源）
    static let insecureEnvVars: [String] = [
        "_MSSafeMode", "DYLD_PRINT_BINDINGS", "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES", "DYLD_PRINT_OPTS", "DYLD_PRINT_ENV",
        "DYLD_SHARED_REGION", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH",
        "CFFIXED_USER_HOME", "HOME", "LOGNAME", "USER",
    ]

    static func checkEnvironmentVariables() -> SecurityCheckResult {
        let found = insecureEnvVars.filter { getenv($0) != nil }
        if found.isEmpty {
            return SecurityCheckResult(id: "env", title: "环境变量",
                detail: "未发现越狱/注入相关的危险环境变量", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "env", title: "环境变量",
            detail: "检测到可疑环境变量：\(found.joined(separator: "、"))",
            passed: false, warn: false)
    }

    // MARK: 2. DYLD 注入库扫描（Reveil checkDYLD 同思路）

    /// 可疑库名片段（Presets: suspiciousLibraries/suspiciousLibraryNames 同源）
    static let suspiciousLibraryFragments: [String] = [
        "frida", "cycript", "cynject", "substrate", "libhooker",
        "tweakinject", "SSLKillSwitch", "RocketBootstrap", "PreferenceLoader",
        "CydiaSubstrate", "MobileSubstrate", "RevealServer", "FridaGadget",
    ]

    static func checkDYLDInjection() -> SecurityCheckResult {
        var loaded: [String] = []
        let count = _dyld_image_count()
        guard count > 0 else {
            return SecurityCheckResult(id: "dyld", title: "动态库注入检测",
                detail: "无法枚举已加载库", passed: false, warn: true)
        }
        for i in 0..<count {
            if let name = _dyld_get_image_name(i) {
                let path = String(cString: name).lowercased()
                for frag in suspiciousLibraryFragments where path.contains(frag.lowercased()) {
                    loaded.append(String(cString: name))
                    break
                }
            }
        }
        if loaded.isEmpty {
            return SecurityCheckResult(id: "dyld", title: "动态库注入检测",
                detail: "已加载 \(count) 个库，未发现 Frida/Substrate 等注入库",
                passed: true, warn: false)
        }
        return SecurityCheckResult(id: "dyld", title: "动态库注入检测",
            detail: "发现注入库：\(loaded.prefix(3).joined(separator: "\n"))",
            passed: false, warn: false)
    }

    // MARK: 3. 可疑 ObjC 类（Presets: suspiciousObjCClasses）

    /// 可疑 ObjC 类名（SecurityPresets 同源：ShadowRuleset 等）
    static let suspiciousClassNames: [(cls: String, sel: String?)] = [
        ("ShadowRuleset", "internalDictionary"),
        ("ShadowRuleset", nil),
        ("_TtC6Shadow", nil),
    ]

    static func checkSuspiciousObjCClasses() -> SecurityCheckResult {
        var found: [String] = []
        for entry in suspiciousClassNames {
            if let cls: AnyClass = NSClassFromString(entry.cls) {
                if let sel = entry.sel, NSObject.self != cls {
                    // 确认存在实例方法
                    if class_getInstanceMethod(cls, NSSelectorFromString(sel)) != nil {
                        found.append("\(entry.cls) [\(sel)]")
                    }
                } else {
                    found.append(entry.cls)
                }
            }
        }
        if found.isEmpty {
            return SecurityCheckResult(id: "objc", title: "可疑运行时类",
                detail: "未发现 Shadow 等越狱检测规避/注入类", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "objc", title: "可疑运行时类",
            detail: "发现可疑类：\(found.joined(separator: "、"))",
            passed: false, warn: false)
    }

    // MARK: 4. 可疑端口探测（Presets: suspiciousPorts + Reveil checkOpenedPorts）

    /// 可疑端口（Presets: suspiciousPorts 同源）
    static let suspiciousPorts: [(port: Int, name: String)] = [
        (27042, "Frida Server"), (4444, "Frida Gadget"),
        (46952, "X.X.T."), (22, "SSH"), (44, "checkra1n"),
    ]

    static func checkSuspiciousPorts() -> SecurityCheckResult {
        var open: [String] = []
        for entry in suspiciousPorts {
            if isPortOpen(entry.port) {
                open.append("\(entry.name) :\(entry.port)")
            }
        }
        if open.isEmpty {
            return SecurityCheckResult(id: "ports", title: "可疑端口",
                detail: "未检测到 Frida/SSH 等越狱工具常驻端口",
                passed: true, warn: false)
        }
        return SecurityCheckResult(id: "ports", title: "可疑端口",
            detail: "检测到端口开放：\(open.joined(separator: "、"))",
            passed: false, warn: false)
    }

    /// TCP connect 探测本地端口（0.3s 超时）
    private static func isPortOpen(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    // MARK: 5. 系统目录可写探测（Reveil checkRestrictedDirectoriesWritable 同思路）

    /// 受限系统目录（Presets: suspiciousAccessibleDirectories 同源）
    static let restrictedDirs = ["/", "/jb/", "/Library/", "/usr/lib/", "/private/var/lib/"]

    static func checkSystemDirsWritable() -> SecurityCheckResult {
        var writable: [String] = []
        for dir in restrictedDirs {
            // 沙箱内写系统目录必失败；成功即沙盒被突破（危险信号）
            let probe = dir + ".escapeos-\(UUID().uuidString)"
            if FileManager.default.createFile(atPath: probe, contents: Data("ok".utf8)) {
                try? FileManager.default.removeItem(atPath: probe)
                writable.append(dir)
            }
        }
        if writable.isEmpty {
            return SecurityCheckResult(id: "writable", title: "系统目录访问",
                detail: "受限系统目录不可写（沙箱隔离正常）", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "writable", title: "系统目录访问",
            detail: "可写入系统目录：\(writable.joined(separator: "、"))——沙箱异常",
            passed: false, warn: false)
    }
}