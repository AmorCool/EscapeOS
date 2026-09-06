import Foundation
import Darwin
import SwiftUI
import UIKit

/// v0.3.203：设备体检引擎 —— 安全检测项执行器。
///
/// 方法论 1:1 移植 Lessica/Reveil（内嵌 IOSSecuritySuite）：越狱环境组 / 沙箱违规组 /
/// 静态完整性组 / 动态完整性组 / 调试模拟器组 / 网络代理组；名单升级为爱思助手
/// SecurityPresets.plist（v0.3.203 起由该 plist 自动生成 SecurityPresets.swift，
/// 比 Reveil 内置名单更新——用户非 LC 容器安装时文件系统检测可用，勿再删项）。
///
/// 检测项（34 项分组内可落地部分，每项三态 passed/warn/failed）：
///   越狱环境：URL Scheme、可疑文件路径、受限目录可写、DYLD 注入库、可疑 ObjC 类
///   沙箱违规：可访问解释器、可访问目录、fork、符号链接
///   逆向工具：可疑可执行、可疑库、可疑端口
///   其它：危险环境变量、越狱/注入入口宏
///
/// 全部基于公开检测方法论；文件系统项在非越狱沙箱内多数为「不存在/不可写」
/// （通过），这是正确行为而非检测失败。

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
        "urlscheme", "files", "writable", "dyld", "objc",
        "interpreters", "symlink", "fork", "executables",
        "ports", "env", "libraryNames",
    ]

    /// 执行全部检查（同步；最耗时项 = 端口探测 ~1.5s）。
    /// 返回 (结果数组, 总分 0-100)
    static func runAll() -> ([SecurityCheckResult], Int) {
        let results: [SecurityCheckResult] = [
            checkURLSchemes(),
            checkSuspiciousFiles(),
            checkSystemDirsWritable(),
            checkDYLDInjection(),
            checkSuspiciousObjCClasses(),
            checkAccessibleInterpreters(),
            checkSuspiciousSymbolicLinks(),
            checkFork(),
            checkSuspiciousExecutables(),
            checkSuspiciousPorts(),
            checkEnvironmentVariables(),
            checkSuspiciousLibraryNames(),
        ]
        let total = max(0, 100 - results.reduce(0) { $0 + $1.penalty })
        return (results, total)
    }

    /// 对某清单逐项 stat 检查，返回存在的可疑路径
    private static func existingPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            // 四重 API 探测（Reveil FileChecker 同思路：绕单点 hook）
            if FileManager.default.fileExists(atPath: path) { return true }
            var st = stat()
            if stat(path, &st) == 0 { return true }
            if let f = fopen(path, "r") { fclose(f); return true }
            return access(path, R_OK) == 0
        }
    }

    // MARK: 1. 越狱商店 URL Scheme（Presets: suspiciousURLSchemes 前 6 白名单 + Reveil 6）

    static func checkURLSchemes() -> SecurityCheckResult {
        // LSApplicationQueriesSchemes 白名单内的 scheme（Info.plist 已声明，见 J 实测值）
        let whitelisted = ["cydia", "undecimus", "sileo", "zbra", "filza", "activator"]
        var found: [String] = []
        for scheme in whitelisted {
            guard let url = URL(string: "\(scheme)://") else { continue }
            if UIApplication.shared.canOpenURL(url) { found.append(scheme) }
        }
        if found.isEmpty {
            return SecurityCheckResult(id: "urlscheme", title: "越狱商店 Scheme",
                detail: "未检测到 Cydia/Sileo/Unc0ver 等越狱商店 URL Scheme",
                passed: true, warn: false)
        }
        return SecurityCheckResult(id: "urlscheme", title: "越狱商店 Scheme",
            detail: "检测到已注册越狱商店 Scheme：\(found.joined(separator: "、"))",
            passed: false, warn: false)
    }

    // MARK: 2. 可疑文件路径（Presets: suspiciousFiles）

    static func checkSuspiciousFiles() -> SecurityCheckResult {
        let found = existingPaths(SecurityPresets.suspiciousFiles)
        if found.isEmpty {
            return SecurityCheckResult(id: "files", title: "可疑文件路径",
                detail: "未发现 Cydia/Filza/Shadow 等越狱工具文件（共检查 \(SecurityPresets.suspiciousFiles.count) 条路径）",
                passed: true, warn: false)
        }
        return SecurityCheckResult(id: "files", title: "可疑文件路径",
            detail: "发现越狱痕迹文件：\(found.prefix(3).joined(separator: "\n"))",
            passed: false, warn: false)
    }

    // MARK: 3. 受限系统目录可写（Presets: suspiciousAccessibleDirectories）

    static func checkSystemDirsWritable() -> SecurityCheckResult {
        var writable: [String] = []
        for dir in SecurityPresets.suspiciousAccessibleDirectories {
            let probe = dir.hasSuffix("/") ? dir : dir + "/"
            let candidate = probe + ".escapeos-\(UUID().uuidString)"
            if FileManager.default.createFile(atPath: candidate, contents: Data("ok".utf8)) {
                try? FileManager.default.removeItem(atPath: candidate)
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

    // MARK: 4. DYLD 注入库（Presets: suspiciousLibraries）

    static func checkDYLDInjection() -> SecurityCheckResult {
        var loaded: [String] = []
        let count = _dyld_image_count()
        guard count > 0 else {
            return SecurityCheckResult(id: "dyld", title: "动态库注入检测",
                detail: "无法枚举已加载库", passed: true, warn: true)
        }
        for i in 0..<count {
            if let name = _dyld_get_image_name(i) {
                let path = String(cString: name).lowercased()
                for frag in SecurityPresets.suspiciousLibraries where path.contains(frag.lowercased()) {
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

    // MARK: 5. 可疑 ObjC 类（Presets: suspiciousObjCClasses）

    static func checkSuspiciousObjCClasses() -> SecurityCheckResult {
        var found: [String] = []
        for entry in SecurityPresets.suspiciousObjCClasses {
            if let cls: AnyClass = NSClassFromString(entry.cls) {
                if let sel = entry.selector {
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

    // MARK: 6. 可访问的解释器（Presets: suspiciousAccessibleInterpreters）

    static func checkAccessibleInterpreters() -> SecurityCheckResult {
        let found = existingPaths(SecurityPresets.suspiciousAccessibleInterpreters)
        if found.isEmpty {
            return SecurityCheckResult(id: "interpreters", title: "可访问解释器",
                detail: "未发现可读的 sshd/bash 等解释器", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "interpreters", title: "可访问解释器",
            detail: "可访问解释器：\(found.joined(separator: "、"))", passed: false, warn: false)
    }

    // MARK: 7. 可疑符号链接（Presets: suspiciousSymbolicLinks）

    static func checkSuspiciousSymbolicLinks() -> SecurityCheckResult {
        let found = existingPaths(SecurityPresets.suspiciousSymbolicLinks)
        if found.isEmpty {
            return SecurityCheckResult(id: "symlink", title: "可疑符号链接",
                detail: "未发现异常的符号链接", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "symlink", title: "可疑符号链接",
            detail: "发现符号链接：\(found.prefix(3).joined(separator: "、"))",
            passed: false, warn: false)
    }

    // MARK: 8. fork 检测（Reveil checkFork 同思路：dlsym RTLD_DEFAULT）

    static func checkFork() -> SecurityCheckResult {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            return SecurityCheckResult(id: "fork", title: "进程权限",
                detail: "无法解析 fork（不判定）", passed: true, warn: true)
        }
        typealias ForkFn = @convention(c) () -> pid_t
        let forkFn = unsafeBitCast(symbol, to: ForkFn.self)
        let pid = forkFn()
        if pid >= 0 {
            // fork 成功 = 沙箱被突破（越狱特征）
            if pid > 0 { kill(pid, SIGKILL) }
            return SecurityCheckResult(id: "fork", title: "进程权限",
                detail: "fork() 成功——沙箱限制缺失（越狱特征）", passed: false, warn: false)
        }
        return SecurityCheckResult(id: "fork", title: "进程权限",
            detail: "fork() 被沙箱拦截（正常）", passed: true, warn: false)
    }

    // MARK: 9. 可疑可执行（Presets: suspiciousExecutables）

    static func checkSuspiciousExecutables() -> SecurityCheckResult {
        let found = existingPaths(SecurityPresets.suspiciousExecutables)
        if found.isEmpty {
            return SecurityCheckResult(id: "executables", title: "可疑可执行文件",
                detail: "未发现 frida-server 等越狱工具可执行", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "executables", title: "可疑可执行文件",
            detail: "发现：\(found.joined(separator: "、"))", passed: false, warn: false)
    }

    // MARK: 10. 可疑端口（Presets: suspiciousPorts）

    static func checkSuspiciousPorts() -> SecurityCheckResult {
        var open: [String] = []
        for entry in SecurityPresets.suspiciousPorts {
            if isPortOpen(entry.port) {
                open.append("\(entry.name) :\(entry.port)")
            }
        }
        if open.isEmpty {
            return SecurityCheckResult(id: "ports", title: "可疑端口",
                detail: "未检测到 Frida/SSH 等越狱工具常驻端口", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "ports", title: "可疑端口",
            detail: "检测到端口开放：\(open.joined(separator: "、"))",
            passed: false, warn: false)
    }

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

    // MARK: 11. 危险环境变量（Presets: insecureEnvironmentVariables）

    static func checkEnvironmentVariables() -> SecurityCheckResult {
        let found = SecurityPresets.insecureEnvironmentVariables.filter { getenv($0) != nil }
        if found.isEmpty {
            return SecurityCheckResult(id: "env", title: "环境变量",
                detail: "未发现越狱/注入相关的危险环境变量", passed: true, warn: false)
        }
        return SecurityCheckResult(id: "env", title: "环境变量",
            detail: "检测到可疑环境变量：\(found.joined(separator: "、"))",
            passed: false, warn: false)
    }

    // MARK: 12. 可疑动态库名（Presets: suspiciousLibraryNames — Reveil 逆向检测精简集）

    static func checkSuspiciousLibraryNames() -> SecurityCheckResult {
        var loaded: [String] = []
        let count = _dyld_image_count()
        guard count > 0 else {
            return SecurityCheckResult(id: "libraryNames", title: "逆向库检测",
                detail: "无法枚举已加载库", passed: true, warn: true)
        }
        for i in 0..<count {
            if let name = _dyld_get_image_name(i) {
                let path = String(cString: name).lowercased()
                for frag in SecurityPresets.suspiciousLibraryNames where path.contains(frag.lowercased()) {
                    loaded.append(String(cString: name))
                    break
                }
            }
        }
        if loaded.isEmpty {
            return SecurityCheckResult(id: "libraryNames", title: "逆向库检测",
                detail: "未发现 FridaGadget/cynject/libcycript/RevealServer 逆向库",
                passed: true, warn: false)
        }
        return SecurityCheckResult(id: "libraryNames", title: "逆向库检测",
            detail: "发现逆向库：\(loaded.prefix(3).joined(separator: "\n"))",
            passed: false, warn: false)
    }
}
