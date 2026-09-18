import SwiftUI
import UIKit

/// App-list scope split requested by the user: All / System / Third-party.
private enum AppListScope: String, CaseIterable, Identifiable {
    case all = "全部应用"
    case system = "系统应用"
    case thirdParty = "三方应用"
    var id: String { rawValue }
}

/// View model for the app picker.
/// Swift 6：本类是 SwiftUI 的 UI 模型，只在主线程读写 → 标 `@MainActor` 是语义正确的隔离，
/// 同时让 `self` 成为 Sendable，内层 `DispatchQueue.main.async { self.x = … }` 的
/// `sending 'self'` 诊断自然消失（该闭包本来就在主线程执行，语义不变）。
/// 后台重活方法（loadIcons / loadAppTypes）相应标 `nonisolated`，
/// discovery 在主线程取好后以参数传入（后台闭包不能直读 MainActor 存储属性）。
@MainActor
final class AppListViewModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var needsPairing = false
    @Published var icons: [String: UIImage] = [:]
    @Published var uninstallStatus: String?
    /// v0.3.181：应用类型（AppStore/企业/AdHoc/开发/未知），key=bundleID.
    @Published var appTypes: [String: AppType] = [:]

    private let discovery = AppDiscovery()
    private let uninstaller = UninstallService.shared
    /// 加载失败后的自动重试任务（LocalDevVPN 开启后无需手动点重试）.
    private var retryTask: Task<Void, Never>?

    var hasPairingFile: Bool { discovery.hasPairingFile }

    var canUninstall: Bool { discovery.canUninstallApps() }

    /// 停止自动重试（页面消失时调用）.
    func stopAutoRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        needsPairing = false
        uninstallStatus = nil
        // Swift 6：主线程先取好 discovery 再进后台闭包（类已标 @MainActor，
        // 后台闭包不能直读 MainActor 隔离的存储属性；AppDiscovery 本身非隔离）.
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let found = try discovery.fetchInstalledApps()
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.apps = found
                    self.errorMessage = nil
                    self.icons = [:]
                    // 成功：取消自动重试.
                    self.stopAutoRetry()
                }
                self.loadIcons(discovery, for: found)
                self.loadAppTypes(for: found)
            } catch let e as AppDiscoveryError {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if case .noPairingFile = e {
                        self.needsPairing = true
                        // 配对文件缺失：不再自动重试（等用户导入）.
                        self.stopAutoRetry()
                    } else {
                        self.errorMessage = e.localizedDescription
                        self.scheduleAutoRetry()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    self.scheduleAutoRetry()
                }
            }
        }
    }

    /// 加载失败后自动重试（v0.2.108 修正）：
    /// - 单次调度：本次 retry 触发 reload 并等其完成后，再由 reload 的 catch
    ///   块决定是否继续下一次.避免旧 `while` 循环在 reload 尚未完成时就调度
    ///   下一个 Task，导致多个 retry 并发、互相覆盖甚至把 tunnel 资源耗尽.
    /// - 间隔 3 秒.v0.2.106 的「端口可达预检」已移除；RSD tunnel_create_rppairing
    ///   自带 3 次重试，直接重试更可靠.
    /// - 配对文件缺失（needsPairing）时不重试.
    private func scheduleAutoRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.retryTask = nil
                self.reload()
            }
        }
    }

    /// Fetch icons concurrently and publish each one as soon as it arrives.
    /// Swift 6：标 `nonisolated`（后台重活，@Published 状态只在主队列闭包里写）；
    /// discovery 由调用方主线程取好后传入.
    nonisolated private func loadIcons(_ discovery: AppDiscovery, for apps: [InstalledApp]) {
        let ids = apps.map { $0.bundleIdentifier }
        guard !ids.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let bundleId = ids[index]
                guard let icon = discovery.appIcon(for: bundleId) else { return }
                DispatchQueue.main.async {
                    self.icons[bundleId] = icon
                }
            }
        }
    }

    /// v0.3.184：拉取设备的 provisioning profiles（misagent）并结合 installation_proxy 已拿到的
    /// applicationType/iTunesAppleID，构建每个 app 的 AppType 映射.
    /// 判定规则见 `AppTypeDetector.detect`.
    ///
    /// v0.3.369：**元数据输入改用与文档浏览同源的带属性 Lookup**
    /// （`FileSharingService.listAppsWithFileSharing()` →
    /// Rust FFI `installation_proxy_lookup_apps`）。此前这里只有
    /// `AppDiscovery.getAllAppsInfo()`（`installation_proxy_get_apps`，**不带**
    /// ReturnAttributes）来的数据，而该调用**不返回 `iTunesMetadata`** ——
    /// 于是 `appleId` / `hasITunesMetadata` 恒为空，共享正版只能落成苹果正版。
    ///
    /// v0.3.376：这条依赖加 20 秒硬超时（原因见下），避免「appTypes 恒空 → 三方胶囊消失」.
    ///
    /// **v0.3.378：改成两版判定，主数据源回到 `get_apps` 快路径**.
    /// 真机 16:29 日志实证：带属性 Lookup 3 次并发、20 秒一个字节不回；而同一次会话里
    /// `get_apps` + profile **2.5 秒**就判完 333 个应用（16:29:41.895 → :44.395）——
    /// 通道是好的，是 Lookup 命令卡死. 所以：
    ///   - 第一版：`get_apps` + profile 立即上屏（胶囊先出现，不再有「整条不显示」）；
    ///   - 第二版：带属性 Lookup 作**可选增强**（独立 15 秒、失败就不补），
    ///     补上 appleId / 正版存在性后再精修一次，共享正版才不会退化成苹果正版.
    /// 两版都写日志（`类型判定完成（第一版/第二版…）`），下次一眼能看出走到哪.
    ///
    /// **v0.3.401（回归修复）**：`FileSharingService.listAppsWithFileSharing(timeout:)`
    /// 的主路径重新是带属性 Lookup，所以**第一版就带着购买邮箱**（`appleId`/`isGenuine`），
    /// 共享正版在第一版即判准；第二版通常命中单飞缓存（幂等回填）。若主路径降级到
    /// `get_apps`（无 `iTunesMetadata`），购买邮箱缺失 → `AppTypeDetector` v0.3.401
    /// 会给出「未识别」，**不会再误判成「苹果正版」**.
    /// Swift 6：标 `nonisolated`（后台重活；appTypes 只在主队列闭包里写，
    /// 方法体不读其它 MainActor 状态——appleID 用 nonisolated 静态方法直读 keychain）.
    nonisolated private func loadAppTypes(for apps: [InstalledApp]) {
        let ids = apps.map { $0.bundleIdentifier }
        LoginLogger.shared.log("[应用管理] 类型判定开始：\(ids.count) 个应用")
        // v0.3.184：当前 Apple ID 用于区分正版 vs 共享（来自 AppStore 登录态）.
        // 为空时 .appStorePersonal / .appStoreShared 退化为 .appStore.
        // v0.3.185：改用 nonisolated 直读 keychain（本方法在后台队列执行，
        // 直接读 MainActor 隔离的 MemoryLimitSettings.shared.appleID 会编译报错）.
        let currentAppleID = MemoryLimitSettings.currentAppleIDDirect()
        // v0.3.192：misagent 全量拉取 + 解析可能产生大内存峰值（每 profile 数十 KB，
        // 设备上可能有 20+ 个），用 .utility 低优先级队列 + autoreleasepool 包裹，
        // 避免在 reload 高频触发时抢占线程导致卡顿/内存压力；与主流程解耦.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // v0.3.378：主数据源改回 **`get_apps` 快路径**。真机日志实证：
            // 带属性 Lookup 会 20 秒一个字节不回（3 次并发全挂），而同一会话里
            // `get_apps` + profile 2.5 秒就判完 333 个应用（16:29:41.895 → :44.395）。
            // 带属性 Lookup 降级为下面的「可选增强」（独立 15 秒、失败就不补）.
            let fast: [FileSharingApp]
            switch FileSharingService.listAppsWithFileSharing(timeout: 20) {
            case .ok(let found):
                fast = found
                LoginLogger.shared.log("[应用管理] get_apps 快路径：\(found.count) 条")
            case .failed(let message):
                fast = []
                LoginLogger.shared.log("[应用管理] get_apps 快路径失败：\(message)；改用 apps + profile 继续判定")
            case .timedOut:
                fast = []
                LoginLogger.shared.log("[应用管理] get_apps 快路径超时；改用 apps + profile 继续判定")
            }
            // v0.3.190：两条隧道必须**顺序串行**调用——fetchSideloadedApps（installation_proxy）
            // 与 fetchAllProfiles（misagent）各自 createTunnel，若并发握手会死锁闪退
            // （v0.3.187 曾在 fetchSideloadedApps 内部嵌套调 fetchAllProfiles = 双隧道并发，
            //  是真机连续闪退元凶）. 现在顺序执行，前一条 defer 释放后才建下一条.
            // v0.3.192：整个 fetch+解析包 autoreleasepool——CMS blob Data / plist 解析
            // 的自动释放对象在每次 reload 后立即回收，防长时间运行内存累积.
            // autoreleasepool(invoking:) 返回闭包结果，避免"let 在闭包内赋值"编译错误.
            let (sideloaded, allProfiles): (
                [ProvisioningProfileStore.SideloadedAppInfo],
                [ProvisioningProfileStore.ProfileInfo]
            ) = autoreleasepool(invoking: {
                (
                    (try? ProvisioningProfileStore.fetchSideloadedApps()) ?? [],
                    (try? ProvisioningProfileStore.fetchAllProfiles()) ?? []
                )
            })
            // 以 bundleID 为 key 的 entitlements 字典
            var entMap: [String: [String: Any]] = [:]
            for s in sideloaded {
                entMap[s.bundleID] = s.entitlements
            }
            // 以 appId（application-identifier）匹配 profile 顶层 ProvisionsAllDevices
            // v0.3.192【闪退修复】：设备上同一 App 重签/多次安装会留下多个指向同一
            // application-identifier 的 profile → Dictionary(uniqueKeysWithValues:)
            // 遇重复 key 直接 fatalError 崩溃（v0.3.187~191 真机闪退真凶）.
            // 改用 uniquingKeysWith 保留首个.
            let profileByAppId = Dictionary(
                allProfiles.map { ($0.appId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var provisionsAllDevicesMap: [String: Bool] = [:]
            for s in sideloaded {
                guard let appId = s.applicationIdentifier,
                      let profile = profileByAppId[appId] else { continue }
                provisionsAllDevicesMap[s.bundleID] = profile.provisionsAllDevices
            }
            // ===== v0.3.378：两版判定（第一版立即上屏，第二版用可选增强精修）=====
            // 增强结果（可能为空 = 没取到/超时，此时按「没有账号/存在性信息」判）
            var enhanced: [FileSharingApp] = []

            // 以 bundleID 为 key 的 applicationType / iTunesAppleID / hasITunesMetadata
            func judge() -> [String: AppType] {
                var appTypeMap: [String: String] = [:]
                var iTunesIDMap: [String: String] = [:]
                // v0.3.367：**必须把「存在 iTunesMetadata」这一事实也传下去**。
                // 原来只传了购买邮箱，而没有元数据的包会被判成非 App Store 下发；
                // 叠加「已装应用读不到包内 sinf（加密状态未知）」，App Store 应用会全被判成越狱版。
                var hasMetadataMap: [String: Bool] = [:]
                for app in fast {
                    // parseAppDict 缺 ApplicationType 时填 "Unknown"，视同未拿到，留给兜底
                    if app.applicationType != "Unknown" {
                        appTypeMap[app.bundleId] = app.applicationType
                    }
                    if let id = app.appleId { iTunesIDMap[app.bundleId] = id }
                    hasMetadataMap[app.bundleId] = app.isGenuine
                }
                // 第二版：带属性 Lookup 的增强值优先覆盖（它是大小/账号字段的唯一来源）
                for app in enhanced {
                    if app.applicationType != "Unknown" {
                        appTypeMap[app.bundleId] = app.applicationType
                    }
                    if let id = app.appleId { iTunesIDMap[app.bundleId] = id }
                    if app.isGenuine { hasMetadataMap[app.bundleId] = true }
                }
                for app in apps {
                    if appTypeMap[app.bundleIdentifier] == nil, let t = app.applicationType {
                        appTypeMap[app.bundleIdentifier] = t
                    }
                    if iTunesIDMap[app.bundleIdentifier] == nil, let id = app.iTunesAppleID {
                        iTunesIDMap[app.bundleIdentifier] = id
                    }
                    if hasMetadataMap[app.bundleIdentifier] == nil {
                        hasMetadataMap[app.bundleIdentifier] = app.hasITunesMetadata
                    }
                }
                // v0.3.190：从 misagent 拉的 mobileprovision 顶层 ProvisionsAllDevices 匹配，
                // 企业判定唯一权威字段（Apple TN3125）——已在上面按 appId 构建 provisionsAllDevicesMap.
                var resolved: [String: AppType] = [:]
                for id in ids {
                    resolved[id] = AppTypeDetector.detect(
                        entitlements: entMap[id] ?? [:],
                        applicationType: appTypeMap[id],
                        iTunesAppleID: iTunesIDMap[id],
                        currentAppleID: currentAppleID,
                        provisionsAllDevices: provisionsAllDevicesMap[id] ?? false,
                        hasITunesMetadata: hasMetadataMap[id] ?? false
                    )
                }
                return resolved
            }

            // 上屏 + 留痕（胶囊是否显示只看这一行有没有跑到）
            // Swift 6：原来这里是局部函数 `publish(_:_:)`，它捕获非 Sendable 的 `self`，
            // 报 "capture of 'self' with non-Sendable type 'AppListViewModel?' in an
            // isolated local function"（DispatchQueue 的 @preconcurrency @Sendable 只把普通
            // 捕获降级成警告，不覆盖「隔离的局部函数」这条错误）。展开成与本文件其它处一致的
            // 「主队列 hop + self? 弱引用」写法，语义不变（`judge()` 仍在后台队列先算好）.

            // 第一版：get_apps + profile —— 立即上屏，**不等**可选增强
            //（用户实测：333 应用场景这条路径 2.5 秒级；胶囊先出现，再被第二版精修）
            let firstResolved = judge()
            let firstNote = "[应用管理] 类型判定完成（第一版·get_apps+profile）：\(ids.count) 条"
                + "（entitlements \(entMap.count) / provisionsAllDevices \(provisionsAllDevicesMap.count)）"
            DispatchQueue.main.async {
                self?.appTypes = firstResolved
                LoginLogger.shared.log(firstNote)
            }

            // 第二版：可选增强（带属性 Lookup，独立 15 秒，失败就不补）
            // v0.3.379：额度 8s→15s（后台可选、不阻塞首屏；单飞保证同一时刻只有一条在飞）；
            // 额度统一在 FileSharingService.lookupAppAttributes 的默认参数里定义，调用方不再传值.
            enhanced = FileSharingService.lookupAppAttributes()
            if enhanced.isEmpty {
                LoginLogger.shared.log("[应用管理] 带属性增强未取到：账号/正版存在性按 apps 兜底（第一版结果保留）")
            } else {
                let secondResolved = judge()
                let secondNote = "[应用管理] 类型判定完成（第二版·含带属性增强）：\(ids.count) 条"
                    + "（增强 \(enhanced.count) 条）"
                DispatchQueue.main.async {
                    self?.appTypes = secondResolved
                    LoginLogger.shared.log(secondNote)
                }
            }
        }
    }

    func importPairingFile(_ contents: String) throws {
        try discovery.importPairingFile(contents)
    }

    /// Parse raw pairing-file bytes (XML plist text, binary plist, or already-text)
    /// and import. Shared by the file picker and the clipboard import path so both
    /// accept exactly the same formats.
    func importPairingFile(from data: Data) throws {
        let contents: String
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            contents = utf8
        } else if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  let text = String(data: xml, encoding: .utf8) {
            contents = text
        } else {
            throw NSError(
                domain: "EscapeOS",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法读取该配对文件."]
            )
        }
        try importPairingFile(contents)
    }

    func resetPairing() {
        discovery.resetPairing()
        apps = []
        icons = [:]
        reload()
    }

    /// Load a single icon on demand (e.g. when opening app detail before batch fetch finishes).
    func ensureIcon(for bundleId: String) {
        guard icons[bundleId] == nil else { return }
        // Swift 6：主线程先取好 discovery（后台闭包不能直读 @MainActor 存储属性）.
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let icon = discovery.appIcon(for: bundleId) else { return }
            DispatchQueue.main.async {
                self.icons[bundleId] = icon
            }
        }
    }

    /// Sequentially uninstall a batch of user apps. Each call goes through
    /// the pairing-file + LocalDevVPN tunnel (`TunnelContext` →
    /// `installation_proxy_uninstall`), authenticated by the trusted pairing
    /// file so `installd` accepts it without a private entitlement. Failures
    /// are collected and surfaced in `uninstallStatus` once the batch
    /// completes — we keep going rather than aborting, so the user gets
    /// partial progress even when one bundle id rejects.
    // Swift 6：completion 会被后台队列闭包捕获（:394），必须标 @Sendable（CI 实测）。
    func uninstallBatch(_ targets: [InstalledApp],
                        completion: @escaping @Sendable ([InstalledApp], [(InstalledApp, Error)]) -> Void) {
        guard canUninstall else {
            completion([], targets.map { ($0, UninstallServiceError.callFailed("尚未导入配对文件")) })
            return
        }
        // Swift 6：主线程先取好 uninstaller（@MainActor 类的存储属性不能在后台闭包直读）；
        // successes/failures 移进队列闭包内部作为局部变量，消除「跨闭包捕获 var」的
        // 数据竞争来源；进度文案在后台先算成 Sendable 字符串再进主队列闭包.
        let uninstaller = self.uninstaller
        let queue = DispatchQueue(label: "escapeos.uninstall", qos: .userInitiated)
        queue.async {
            var successes: [InstalledApp] = []
            var failures: [(InstalledApp, Error)] = []
            for app in targets {
                let status = "正在卸载 \(app.name) (\(successes.count + failures.count + 1) / \(targets.count))…"
                DispatchQueue.main.async {
                    self.uninstallStatus = status
                }
                do {
                    try uninstaller.uninstall(bundleId: app.bundleIdentifier)
                    successes.append(app)
                } catch {
                    failures.append((app, error))
                }
            }
            // Swift 6：先拷贝成不可变值、原变量此后不再使用，跨入主队列闭包
            // 才满足「sending 要求发送后区域闭合」的诊断.
            let doneSuccesses = successes
            let doneFailures = failures
            DispatchQueue.main.async {
                self.uninstallStatus = nil
                completion(doneSuccesses, doneFailures)
                // Refresh app list so system apps-removed / leftover apps reflect.
                self.reload()
            }
        }
    }
}

/// Scrollable list of installed user apps, with search, A–Z jump index,
/// and a multi-select mode that uninstalls chosen apps through the
/// pairing-file + LocalDevVPN tunnel (`installation_proxy_uninstall`).
struct AppListView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var searchText = ""
    @State private var appTypeFilter: AppListScope = .all
    @State private var iconShare: IconSharePayload?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingUninstall: [InstalledApp] = []
    @State private var uninstallResult: UninstallResultNotice?

    var body: some View {
        let visible = filteredApps
        List {
                Section {
                    Picker("应用类型", selection: $appTypeFilter) {
                        ForEach(AppListScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                // v0.3.245：配对文件缺失引导统一走 PairingGuideCard（独立卡片板块，
                // 图标块+标题+描述+钥匙导航行，与其余功能页同一视觉）
                if viewModel.needsPairing {
                    Section {
                        PairingGuideCard(showsBackground: false, note: "重置配对文件后，到「更多 → 配对文件导入」重新导入即可恢复应用列表.")
                            .listRowInsets(EdgeInsets())
                    }
                }

                if let status = viewModel.uninstallStatus {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text(status)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                if visible.isEmpty {
                    Text(emptyListMessage)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sections(in: visible), id: \.letter) { section in
                        Section(header: Text(section.letter).id(section.letter)) {
                            ForEach(section.apps) { app in
                                if app.isSystem {
                                    // 系统应用同样支持进入详情页：浏览文件 / 回收空间 /
                                    // 备份数据 / 重置应用数据（重置有额外二次风险确认，
                                    // 见 AppDetailView）.系统应用不参与批量选择与卸载.
                                    NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                        appRow(app, mode: .normal)
                                    }
                                    .contextMenu {
                                        Button {
                                            FileClipboard.copyText(
                                                app.bundleIdentifier,
                                                confirmation: "已复制 Bundle ID"
                                            )
                                        } label: {
                                            Label("复制 Bundle ID", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            FileClipboard.copyText(app.name, confirmation: "已复制名称")
                                        } label: {
                                            Label("复制名称", systemImage: "character.cursor.ibeam")
                                        }
                                        if let icon = viewModel.icons[app.bundleIdentifier] {
                                            Button {
                                                iconShare = IconSharePayload(image: icon, suggestedName: "\(app.name) 图标.png")
                                            } label: {
                                                Label("提取图标", systemImage: "square.and.arrow.down")
                                            }
                                        }
                                    }
                                } else if selecting {
                                    Button {
                                        toggleSelection(app.bundleIdentifier)
                                    } label: {
                                        appRow(app, mode: .select(isSelected: selected.contains(app.bundleIdentifier)))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                        appRow(app, mode: .normal)
                                    }
                                    .contextMenu {
                                        Button {
                                            FileClipboard.copyText(
                                                app.bundleIdentifier,
                                                confirmation: "已复制 Bundle ID"
                                            )
                                        } label: {
                                            Label("复制 Bundle ID", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            FileClipboard.copyText(app.name, confirmation: "已复制名称")
                                        } label: {
                                            Label("复制名称", systemImage: "character.cursor.ibeam")
                                        }
                                        if let icon = viewModel.icons[app.bundleIdentifier] {
                                            Button {
                                                iconShare = IconSharePayload(image: icon, suggestedName: "\(app.name) 图标.png")
                                            } label: {
                                                Label("提取图标", systemImage: "square.and.arrow.down")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用")
        .toolbar {
            if selecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        selecting = false
                        selected.removeAll()
                    }
                    .disabled(viewModel.uninstallStatus != nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selectingAllVisible ? "取消全选" : "全选") {
                        toggleSelectAll(visible: visible)
                    }
                    .disabled(viewModel.uninstallStatus != nil || visible.isEmpty)
                }
            } else {
                if appTypeFilter != .system {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("选择") {
                            selected.removeAll()
                            selecting = true
                        }
                        .disabled(viewModel.apps.isEmpty)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                selectionBar
            }
        }
        .alert("卸载选中应用？", isPresented: Binding(
            get: { !pendingUninstall.isEmpty },
            set: { if !$0 { pendingUninstall = [] } }
        )) {
            Button("取消", role: .cancel) { pendingUninstall = [] }
            Button("卸载", role: .destructive) { startUninstall() }
        } message: {
            Text(uninstallConfirmMessage)
        }
        .alert(item: $uninstallResult) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
        .sheet(item: $iconShare) { payload in
            IconShareSheet(image: payload.image, fileName: payload.suggestedName)
        }
        // 用户切到后台去开 LocalDevVPN，回到前台时主动刷新一次.
        // 与缩短后的 15s 超时配合，能更快从"开 App 后才连 VPN"的场景恢复.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.reload()
        }
    }

    // MARK: - Selection helpers

    private func toggleSelection(_ bundleId: String) {
        if selected.contains(bundleId) {
            selected.remove(bundleId)
        } else {
            selected.insert(bundleId)
        }
    }

    private var selectingAllVisible: Bool {
        let selectable = filteredApps.filter { !$0.isSystem }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.bundleIdentifier) }
    }

    private func toggleSelectAll(visible: [InstalledApp]) {
        let selectable = visible.filter { !$0.isSystem }
        if selectingAllVisible {
            for app in selectable {
                selected.remove(app.bundleIdentifier)
            }
        } else {
            for app in selectable {
                selected.insert(app.bundleIdentifier)
            }
        }
    }

    private var selectionBar: some View {
        let apps = filteredApps.filter { selected.contains($0.bundleIdentifier) && !$0.isSystem }
        return HStack {
            Text("已选 \(apps.count) 项")
                .font(.subheadline)
            Spacer()
            Button(role: .destructive) {
                pendingUninstall = apps
            } label: {
                Label("卸载", systemImage: "trash")
            }
            .disabled(apps.isEmpty || !viewModel.canUninstall || viewModel.uninstallStatus != nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var uninstallConfirmMessage: String {
        let n = pendingUninstall.count
        let prefix = "将卸载 \(n) 个应用.iOS 可能会弹出系统确认对话框."
        if !viewModel.canUninstall {
            return prefix + "（⚠️ 配对文件未导入 — 请到「更多 → 配对文件导入」重新导入.）"
        }
        return prefix
    }

    private func startUninstall() {
        let toRemove = pendingUninstall
        pendingUninstall = []
        viewModel.uninstallBatch(toRemove) { _, failures in
            // Successful apps are removed by installd; we just refresh.
            let succeeded = toRemove.count - failures.count
            var msg = "已卸载 \(succeeded) 个应用."
            if !failures.isEmpty {
                let names = failures.map { "\($0.0.name)（\($0.1.localizedDescription)）" }.joined(separator: "\n")
                msg += "\n失败 \(failures.count) 个：\n\(names)"
            }
            uninstallResult = UninstallResultNotice(title: "卸载完成", message: msg)
            selected.removeAll()
            selecting = false
        }
    }

    // MARK: - Row layout

    private enum RowMode { case normal, select(isSelected: Bool) }

    private func appRow(_ app: InstalledApp, mode: RowMode) -> some View {
        HStack(spacing: 12) {
            if case let .select(checked) = mode {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(checked ? .accentColor : .secondary)
            }
            AppIconView(icon: viewModel.icons[app.bundleIdentifier])
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body)
                    if app.isSystem {
                        Text("系统")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    } else if let type = viewModel.appTypes[app.bundleIdentifier] {
                        AppTypeBadge(type: type, compact: true)
                    }
                }
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyListMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "未找到应用."
        }
        return "没有匹配 “\(query)” 的应用."
    }

    private var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = viewModel.apps.filter { app in
            switch appTypeFilter {
            case .all: return true
            case .system: return app.isSystem
            case .thirdParty: return !app.isSystem
            }
        }
        guard !query.isEmpty else { return scoped }
        return scoped.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func sections(in apps: [InstalledApp]) -> [(letter: String, apps: [InstalledApp])] {
        let grouped = Dictionary(grouping: apps) { app -> String in
            let folded = app.name.folding(options: .diacriticInsensitive, locale: .current)
            guard let ch = folded.uppercased().first, ch.isLetter else { return "#" }
            return String(ch)
        }
        let keys = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return keys.map { letter in
            let rows = (grouped[letter] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return (letter, rows)
        }
    }

}

/// Local `Identifiable` wrapper for showing the post-batch uninstall summary.
struct UninstallResultNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Payload passed to `IconShareSheet` when sharing an extracted app icon.
struct IconSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let suggestedName: String
}

/// Wraps `UIActivityViewController` to share an extracted app icon. The user
/// can save it to the Photos library, Files, AirDrop, etc.
struct IconShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Materialize the PNG into a temp file so "Save to Files" gives the
        // icon a meaningful name. `UIActivityViewController` will copy the
        // file when the user chooses a file destination.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
