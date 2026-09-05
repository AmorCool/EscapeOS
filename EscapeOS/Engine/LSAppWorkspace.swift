import Foundation
import ObjectiveC.runtime

/// LSApplicationWorkspace 私有 API 封装（v0.3.179 应用板块·系统应用卸载）：
/// 动态枚举已安装应用 + 识别 Apple 官方"可卸载系统应用"（removableSystemApp）。
/// 不依赖固定名单——系统应用的 removable 标记由 Apple 随系统版本维护，
/// 这里通过 KVC 探测（removableSystemApp / isRemovable），探测失败再回退
/// 最小核心排除名单兜底（绝不建议卸载的系统组件）。
final class LSAppWorkspace {
    static let shared = LSAppWorkspace()

    struct SystemApp: Identifiable, Hashable {
        let id: String          // bundleID
        let name: String
        let bundleID: String
        let removable: Bool
    }

    /// 卸载后系统仍可从 App Store 重新下载恢复，但操作本身不可即时撤销.
    private static let coreKeepList: Set<String> = [
        "com.apple.springboard",
        "com.apple.MobilePhone",
        "com.apple.mobilephone",
        "com.apple.MobileSMS",
        "com.apple.mobilesms",
        "com.apple.mobilesafari",
        "com.apple.Preferences",
        "com.apple.AppStore",
        "com.apple.MobileStore",
        "com.apple.camera",
        "com.apple.mobileslideshow",
        "com.apple.purplebuddy",     // Setup
        "com.apple.dataaccess.dataaccessd",
        "com.apple.facetime",
        "com.apple.FaceTime",
        "com.apple.Health",
        "com.apple.mobileme.fmf1",   // Find My
        "com.apple.findmy",
        "com.apple.mobiletimer",
        "com.apple.calls.callstatedbservice",
        "com.apple.webapp",
    ]

    private let workspace: NSObject?

    private init?() {
        let frameworkPaths = [
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework",
            "/System/Library/Frameworks/MobileCoreServices.framework",
        ]
        var loadedClass: AnyClass?
        for path in frameworkPaths {
            if let bundle = Bundle(path: path) {
                _ = bundle.load()
                if let cls = NSClassFromString("LSApplicationWorkspace") {
                    loadedClass = cls
                    break
                }
            }
        }
        guard let cls = loadedClass,
              let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?
                  .takeUnretainedValue() as? NSObject else {
            return nil
        }
        workspace = ws
    }

    /// 动态枚举系统应用（applicationType == "System"），并识别可卸载标记.
    func systemApps() -> [SystemApp] {
        guard let workspace else { return [] }
        let sel = NSSelectorFromString("allInstalledApplications")
        guard workspace.responds(to: sel),
              let proxies = workspace.perform(sel)?
                  .takeUnretainedValue() as? [NSObject] else {
            return []
        }

        var result: [SystemApp] = []
        var seen = Set<String>()
        for proxy in proxies {
            let bundleID = (proxy.value(forKey: "applicationIdentifier") as? String)
                ?? (proxy.value(forKey: "bundleIdentifier") as? String) ?? ""
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            let appType = (proxy.value(forKey: "applicationType") as? String) ?? ""
            guard appType == "System" else { continue }
            seen.insert(bundleID)

            let name = (proxy.value(forKey: "localizedName") as? String) ?? bundleID

            // 可卸载判定：优先 Apple 自己的 removable 标记（KVC 探测），
            // 再回退核心排除名单（不在名单内的系统应用视为可卸载候选）.
            var removable = false
            if proxy.responds(to: NSSelectorFromString("removableSystemApp")),
               let flag = proxy.value(forKey: "removableSystemApp") as? Bool {
                removable = flag
            } else if proxy.responds(to: NSSelectorFromString("isRemovable")),
                      let flag = proxy.value(forKey: "isRemovable") as? Bool {
                removable = flag
            } else {
                removable = !Self.coreKeepList.contains(bundleID)
            }
            // 核心组件无论标记如何一律不可卸载（双保险）
            if Self.coreKeepList.contains(bundleID) {
                removable = false
            }
            result.append(SystemApp(id: bundleID, name: name, bundleID: bundleID, removable: removable))
        }
        return result.sorted {
            if $0.removable != $1.removable { return $0.removable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 卸载系统应用（bundleID）。iOS 15+ 私有 selector 带NSError** 出参，
    /// Swift perform 无法直接传——用 method IMP cast 调用.
    @discardableResult
    func uninstallSystemApp(bundleID: String) -> Bool {
        guard let workspace else { return false }
        let twoArg = NSSelectorFromString("uninstallSystemApplicationWithBundleID:error:")
        if let method = class_getInstanceMethod(type(of: workspace), twoArg) {
            typealias Fn = @convention(c) (NSObject, Selector, NSString,
                UnsafeMutablePointer<UnsafeMutablePointer<NSError>?>?) -> ObjCBool
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            var err: NSError?
            let ok = fn(workspace, twoArg, bundleID as NSString, &err)
            return ok.boolValue && err == nil
        }
        let oneArg = NSSelectorFromString("uninstallSystemApplication:")
        if workspace.responds(to: oneArg) {
            let result = workspace.perform(oneArg, with: bundleID)
            return result != nil
        }
        return false
    }
}
