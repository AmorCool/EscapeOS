import SwiftUI
import UIKit
import SafariServices
import Darwin

/// 监督模式工具共用的小组件：App 图标（私有 API）、已安装应用枚举、底部安装按钮、app 内 Safari.

/// 通过私有 API 取得已安装 App 的图标（与 Lithium 一致）.
/// 需在 EscapeOS-Bridging-Header.h 中声明
/// `+ (instancetype)_applicationIconImageForBundleIdentifier:format:scale:`.
func supervisedAppIcon(_ bundleID: String) -> Image {
    guard let img = UIImage._applicationIconImage(forBundleIdentifier: bundleID, format: 1, scale: UIScreen.main.scale) else {
        return Image(systemName: "app.dashed")
    }
    return Image(uiImage: img)
}

/// 设备本地枚举已安装应用（LSApplicationWorkspace 私有 API）.
///
/// 实现要点（Theos / 证书直装环境，三条缺一不可）：
/// 1. **必须先 dlopen 加载 framework**：`NSClassFromString` 只搜索「已加载」的类，
///    不会自动加载 framework.CoreServices 未被链接/加载时 NSClassFromString
///    直接返回 nil（v0.2.66 列表仍为空的原因）.
/// 2. 通过 `(AnyObject).perform` + KVC 反射调用，不产生编译期类符号引用，
///    避免 `_OBJC_CLASS_$_` Undefined symbols（Theos 下未链接 CoreServices 的坑）.
/// 3. 不需要配对文件 / 本地隧道，证书直装环境直接可用.
/// 只返回用户安装的应用（User / Internal）——隐藏对系统 App 无效.
func supervisedInstalledApps() -> [InstalledApp] {
    // 先强制加载可能承载 LSApplicationWorkspace 的 framework.
    // iOS 14+ 在 CoreServices；旧版本在 MobileCoreServices.dlopen 失败无害.
    for path in [
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
    ] {
        dlopen(path, RTLD_NOW)
    }

    guard let wsClass = NSClassFromString("LSApplicationWorkspace") as AnyObject?,
          let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue(),
          let proxies = ws.perform(NSSelectorFromString("allApplications"))?.takeUnretainedValue() as? [NSObject] else {
        return []
    }
    var result: [InstalledApp] = []
    for proxy in proxies {
        guard let bid = proxy.value(forKey: "bundleIdentifier") as? String else { continue }
        let type = (proxy.value(forKey: "applicationType") as? String) ?? "User"
        if type == "System" || type == "HiddenSystemApp" { continue }
        let nm = (proxy.value(forKey: "localizedName") as? String) ?? ""
        result.append(InstalledApp(
            bundleIdentifier: bid,
            name: nm.isEmpty ? bid : nm,
            containerPath: "",
            version: nil,
            applicationType: type
        ))
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// 「从已安装应用选择」为空的诊断信息（供空列表展示，便于区分根因）.
func supervisedEnumerationDiagnostic() -> String {
    if NSClassFromString("LSApplicationWorkspace") == nil {
        return "应用列表服务不可用：无法加载 LSApplicationWorkspace（framework 加载失败）."
    }
    return "未找到已安装的三方应用."
}

/// app 内 Safari 的展示目标（URL 需要 Identifiable 才能用 `.sheet(item:)`）.
struct SafariTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// 用 app 内 SFSafariViewController 打开描述文件安装页.
/// 与 Lithium 原版一致：保持本应用前台，本地 HTTP 服务器不会因进程
/// 被挂起而失联（跳外部 Safari 时应用退后台会被 iOS 挂起，accept 线程
/// 停摆，导致 meta refresh 后的第二次请求连不上服务器）.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// 底部统一的「安装描述文件」按钮条.
struct SupervisedInstallFooter: ViewModifier {
    let title: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
    }
}

extension View {
    /// 给监督模式工具页添加统一的底部安装按钮.
    func supervisedInstallFooter(title: String = "安装描述文件", action: @escaping () -> Void) -> some View {
        self.modifier(SupervisedInstallFooter(title: title, action: action))
    }
}

// MARK: - 已登记应用目录持久化

/// 一份已登记目录（隐藏列表 / 通知列表）的读取结果。
///
/// `writable == false` = **这一次没能完整读出目录**（键值类型异常 / JSON 整份坏 /
/// 有记录解不出）。调用方**必须只读、绝不回写** —— 否则会把没读到的登记项当成
/// 「不存在」而覆盖掉：用户会看到「已登记应用」变空，一保存就把真台账清空。
///
/// 与「文件不存在 = 合法空」必须分开：键不存在是合法的空目录（`writable == true`），
/// 键存在却读不出才是不可写。两者压成同一个状态，正是本项目反复踩过的
/// 「没能观察到 ≠ 确定没有」。
struct SupervisedCatalogLoad<Item> {
    let items: [Item]
    let writable: Bool
    let note: String?
}

/// 把「可隐藏 App」与「通知管理 App」的目录以 JSON 存入 UserDefaults.
/// 用 JSON Data 而非 `@AppStorage(Codable)`，避免不同 SDK 对 @AppStorage
/// 的 Codable 支持差异导致编译失败.
extension UserDefaults {
    private enum Keys {
        static let hiddenApps = "esc_hiddenApps"
        static let notificationApps = "esc_notificationApps"
    }

    /// 读「可隐藏 App」目录。键不存在 = 合法空（可写）；存在但读不全 = 不可写。
    func loadEscHiddenApps() -> SupervisedCatalogLoad<HiddenAppItem> {
        loadEscCatalog(key: Keys.hiddenApps, label: "隐藏应用目录")
    }

    /// 读「通知管理 App」目录。键不存在 = 合法空（可写）；存在但读不全 = 不可写。
    func loadEscNotificationApps() -> SupervisedCatalogLoad<NotificationEntry> {
        loadEscCatalog(key: Keys.notificationApps, label: "通知管理目录")
    }

    /// 写「可隐藏 App」目录。**调用方必须先确认 `loadEscHiddenApps().writable == true`。**
    func saveEscHiddenApps(_ items: [HiddenAppItem]) {
        saveEscCatalog(items, key: Keys.hiddenApps, label: "隐藏应用目录")
    }

    /// 写「通知管理 App」目录。**调用方必须先确认 `loadEscNotificationApps().writable == true`。**
    func saveEscNotificationApps(_ items: [NotificationEntry]) {
        saveEscCatalog(items, key: Keys.notificationApps, label: "通知管理目录")
    }

    /// 读取一份已登记目录。**任何丢失都令 `writable = false`**（本次只读、不回写）。
    private func loadEscCatalog<Item: Decodable>(key: String,
                                                 label: String) -> SupervisedCatalogLoad<Item> {
        // 键不存在 = 合法空目录（首次运行 / 从没登记过），可以写。
        guard let obj = object(forKey: key) else {
            return SupervisedCatalogLoad(items: [], writable: true, note: nil)
        }
        // 键存在、但不是 Data —— 值被别的东西写坏/覆盖，读不出，不可写。
        guard let data = obj as? Data else {
            return SupervisedCatalogLoad(items: [], writable: false,
                note: "\(label)键值类型异常（不是 Data），本次按只读处理，不回写")
        }
        let dec = JSONDecoder()
        // 1) 快路径：整份解得出
        if let list = try? dec.decode([Item].self, from: data) {
            return SupervisedCatalogLoad(items: list, writable: true, note: nil)
        }
        // 2) 整份解失败 → **逐条**解，能救多少救多少（单条坏记录不再拖垮整份目录）。
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return SupervisedCatalogLoad(items: [], writable: false,
                note: "\(label) JSON 解析失败（数据损坏），本次按只读处理，不回写")
        }
        var salvaged: [Item] = []
        for element in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: element),
                  let item = try? dec.decode(Item.self, from: d) else { continue }
            salvaged.append(item)
        }
        guard !salvaged.isEmpty else {
            return SupervisedCatalogLoad(items: [], writable: false,
                note: "\(label) \(raw.count) 条全部无法解析，本次按只读处理，不回写")
        }
        // 有救回来的条目，但仍**不写盘**：写回会把解不出的那几条永久抹掉。
        return SupervisedCatalogLoad(items: salvaged, writable: false,
            note: "\(label) \(raw.count) 条里有 \(raw.count - salvaged.count) 条无法解析，"
                + "本次按只读处理，不回写（原值保留）")
    }

    /// 写入一份已登记目录。编码失败**不静默**（否则调用方以为已持久化）。
    private func saveEscCatalog<Item: Encodable>(_ items: [Item], key: String, label: String) {
        do {
            set(try JSONEncoder().encode(items), forKey: key)
        } catch {
            LoginLogger.shared.log("[监督模式] \(label)编码失败，未写盘（\(items.count) 条）",
                                   category: .general)
        }
    }
}
