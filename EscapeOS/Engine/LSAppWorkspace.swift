import Foundation
import ObjectiveC.runtime

/// LSApplicationWorkspace 私有 API 封装（v0.3.179 应用板块·系统应用卸载）：
/// 动态枚举系统应用，可卸载性**只信任 Apple 自己的 removableSystemApp 标记**
/// （由系统按版本维护，不硬编码任何名单）。
final class LSAppWorkspace {
    static let shared = LSAppWorkspace()

    struct SystemApp: Identifiable, Hashable {
        let id: String          // bundleID
        let name: String
        let bundleID: String
        /// true = Apple 标记为可卸载（removableSystemApp）
        let removable: Bool
    }

    /// allInstalledApplications 的返回值处理（NSArray → [NSObject]）。
    private static let allAppsSelector = NSSelectorFromString("allInstalledApplications")

    private let workspace: NSObject?

    private init?() {
        var targetClass: AnyClass?
        for path in [
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework",
            "/System/Library/Frameworks/MobileCoreServices.framework",
        ] {
            if let bundle = Bundle(path: path) {
                _ = bundle.load()
            }
            if let cls = NSClassFromString("LSApplicationWorkspace") {
                targetClass = cls
                break
            }
        }
        guard let cls = targetClass else { return nil }
        // defaultWorkspace 是类方法——Swift 无法对 AnyClass 发 perform，
        // 用 class_getClassMethod + IMP cast 调用.
        let sel = NSSelectorFromString("defaultWorkspace")
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        // method_getImplementation 返回 IMP（非 Optional，方法存在即非空）
        let imp = method_getImplementation(method)
        typealias DefaultFn = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>?
        let fn = unsafeBitCast(imp, to: DefaultFn.self)
        guard let ws = fn(cls, sel)?.takeUnretainedValue() else { return nil }
        workspace = ws
    }

    /// 动态枚举系统应用（applicationType == "System"）。
    /// removable 判定顺序：
    ///   1. removableSystemApp（Apple 官方标记，唯一权威来源）
    ///   2. isRemovable（旧版备选标记）
    ///   都不存在时按不可卸载处理（保守，避免误卸系统组件）
    func systemApps() -> [SystemApp] {
        guard let workspace else { return [] }
        guard workspace.responds(to: Self.allAppsSelector),
              let raw = workspace.perform(Self.allAppsSelector)?.takeUnretainedValue() as? [Any] else {
            return []
        }
        let proxies = raw.compactMap { $0 as? NSObject }

        var result: [SystemApp] = []
        var seen = Set<String>()
        let removableSel = NSSelectorFromString("removableSystemApp")
        let isRemovableSel = NSSelectorFromString("isRemovable")

        for proxy in proxies {
            let bundleID = (proxy.value(forKey: "applicationIdentifier") as? String)
                ?? (proxy.value(forKey: "bundleIdentifier") as? String) ?? ""
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            let appType = (proxy.value(forKey: "applicationType") as? String) ?? ""
            guard appType == "System" else { continue }
            seen.insert(bundleID)

            let name = (proxy.value(forKey: "localizedName") as? String) ?? bundleID

            var removable = false
            if proxy.responds(to: removableSel),
               let flag = proxy.value(forKey: "removableSystemApp") as? Bool {
                removable = flag
            } else if proxy.responds(to: isRemovableSel),
                      let flag = proxy.value(forKey: "isRemovable") as? Bool {
                removable = flag
            }
            // 不存在的标记一律视为不可卸载（保守）

            result.append(SystemApp(id: bundleID, name: name, bundleID: bundleID, removable: removable))
        }
        return result.sorted {
            if $0.removable != $1.removable { return $0.removable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 卸载系统应用（bundleID）。
    /// 优先 uninstallSystemApplicationWithBundleID:error:（iOS 15+，带出参），
    /// Swift 无法用 perform 传 NSError**，用 method IMP cast 调用；
    /// 老系统回退 uninstallSystemApplication:.
    @discardableResult
    func uninstallSystemApp(bundleID: String) -> Bool {
        guard let workspace else { return false }
        let twoArg = NSSelectorFromString("uninstallSystemApplicationWithBundleID:error:")
        if let method = class_getInstanceMethod(type(of: workspace), twoArg) {
            typealias UninstallFn = @convention(c) (NSObject, Selector, NSString,
                                                    UnsafeMutablePointer<NSError?>) -> ObjCBool
            let fn = unsafeBitCast(method_getImplementation(method), to: UninstallFn.self)
            var error: NSError?
            let ok = fn(workspace, twoArg, bundleID as NSString, &error)
            if ok.boolValue, error == nil {
                return true
            }
            return false
        }
        let oneArg = NSSelectorFromString("uninstallSystemApplication:")
        if workspace.responds(to: oneArg) {
            return workspace.perform(oneArg, with: bundleID) != nil
        }
        return false
    }
}
