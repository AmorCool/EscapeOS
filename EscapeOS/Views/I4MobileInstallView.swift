import SwiftUI
import UniformTypeIdentifiers
import UIKit   // `UIPasteboard`（复制来源安装地址，沿用本仓既有写法）

/// Swift 6：把非 Sendable 的 `DeviceInfoModel`（含 `raw: [String: Any]`）从 `Task.detached`
/// 边界**转移**回主线程时用的薄包装（与 DeviceInfoView 的 DeviceInfoBox 同款，命名避开重名）.
private struct I4MobileDeviceBox<T>: @unchecked Sendable { let value: T }

/// 「安装爱思移动端」页 —— 把爱思 9.0 的「安装爱思移动端」对话框移植过来.
///
/// ## 这个页面是什么
/// 爱思 PC 端的「安装爱思移动端」会往设备推一个「爱思助手移动端」App，并弹出一个对话框
/// （设备信息 + 安装状态 + 「开启高级功能」按钮）。本页复刻该对话框的**界面结构**：
///   1. 设备信息卡（机型 / 容量·颜色 / 序列号 / 系统版本，取自 `DeviceInfoService`）；
///   2. 状态区（尚未开始 / 正在安装 / 安装成功 / 安装未完成）；
///   3. 动作按钮（开始安装 / 开启高级功能）.
///
/// ## 诚实边界（装之前必须让用户看到）
/// 「爱思移动端」是一组伪装成笔记/工具类的 iOS App（React Native 马甲包，bundle id 如
/// `com.ownbook.notes` / `rn.notes.best`）。爱思 PC 安装包里内嵌的 3 个 IPA（`217` / `220` / `photo`）
/// 是 **FairPlay 加密包（`cryptid=1`）**，依赖爱思的共享 Apple ID 授权；本仓现有通道**装不了它**，
/// 即便装上也可能在启动时 `fairplayOpen()` 失败而闪退（即 `-42112` 一类）。
/// ⇒ 本页是**界面移植**，默认**不含可用安装后端**（`installAction == nil`），状态区如实标注.
///
/// ## 不内嵌第三方资源
/// 爱思 logo 是第三方商标，本页**不内嵌其图片资源**；顶部用 SF Symbol 圆角色块占位.
struct I4MobileInstallView: View {
    /// 安装阶段（本页自有状态机；文案不硬编码「安装中」等下载状态字面量）.
    private enum Stage: Equatable {
        case idle
        case installing
        case succeeded
        case failed(String)
    }

    /// 外部注入：安装动作.`nil` ⇒ 页面显示「安装服务未接入」并禁用主按钮.
    /// 说明：爱思移动端是 FairPlay 加密马甲包，本仓暂无可用安装后端，故默认为 nil.
    var installAction: (() async throws -> Void)? = nil

    @State private var info: DeviceInfoModel?
    @State private var loading = true
    @State private var errorText: String?
    @State private var stage: Stage = .idle
    @State private var advancedShown = false

    /// IPA 来源区（两条云端下载 / 手动导入）：各包缓存状态 + 下载进度 + 导入选择器.
    @State private var packStatuses: [I4MobileInstallService.PackStatus] = []
    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var importing = false
    @State private var showImporter = false
    @State private var ipaMessage: String?
    /// 当前选中的云端下载来源（用户可选；默认仓库云端）.
    @State private var selectedSource: I4MobileInstallService.CloudSource = .warehouse
    /// 爱思云端解析器（可注入；默认用**真实实现** —— 契约已坐实，见 `I4CloudResolverImpl`）.
    private let i4Resolver: I4MobileInstallService.I4CloudResolver =
        I4MobileInstallService.I4CloudResolverImpl()
    /// 已下载 IPA 数量（下载管理入口的数量徽标；进页面时读一次磁盘台账）.
    @State private var downloadedCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.section) {
                heroCard
                deviceInfoCard
                ipaSourceCard
                downloadManagerCard
                statusCard
            }
            .padding(AppTheme.pageInset)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("安装爱思移动端")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .documentPicker(isPresented: $showImporter,
                        allowedTypes: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
            guard let url = urls.first else { return }
            Task { await importPicked(url) }
        }
        .alert("开启高级功能", isPresented: $advancedShown) {
            Button("好", role: .cancel) {}
        } message: {
            Text("高级功能由设备端「爱思移动端」App 提供.本机未安装该 App 时，此入口无法生效.")
        }
    }

    // MARK: - 顶部（logo 占位，不内嵌第三方图片）

    private var heroCard: some View {
        HStack(spacing: 14) {
            // 爱思 logo 是第三方商标：用 SF Symbol + 圆角色块占位，不盗图.
            // 底改白色半透明：置于品牌深藏青渐变上，白图形对比清晰（TRApp AppIcon 语言）.
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.inner, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .appSymbol()
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("安装爱思移动端")
                    .font(AppFont.title3)
                    .foregroundStyle(.white)
                Text("爱思 9.0 移动端安装向导")
                    .font(AppFont.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(AppMetrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppTheme.brandGradient)
        )
    }

    // MARK: - 设备信息卡（机型 / 容量·颜色 / 序列号 / 系统版本）

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            Text("设备信息").font(AppFont.headline)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取设备信息…").font(AppFont.caption).foregroundStyle(.secondary)
                }
            } else if let errorText {
                Text(errorText).font(AppFont.caption).foregroundStyle(.red)
            } else if let info {
                infoRow("机型", info.deviceName ?? info.modelName)
                infoRow("容量 / 颜色", capacityColorText(info) ?? "未知")
                infoRow("序列号", info.serialNumber ?? "未知")
                infoRow("系统版本", "iOS \(info.systemVersion)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(AppFont.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(AppFont.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    /// 容量 + 机身颜色（爱思显示「512GB 黑色」）。颜色名只在有实证映射时才翻译；
    /// 无映射时如实显示原始颜色代码，不编造颜色表（口径同 DeviceInfoView.capacityColorText）.
    private func capacityColorText(_ info: DeviceInfoModel) -> String? {
        guard info.storageTotalGB > 0 else { return nil }
        let cap = "\(info.storageTotalGB)GB"
        if let name = DeviceCatalog.deviceColorName(info.deviceColor) { return "\(cap) \(name)" }
        if let code = info.deviceColor, !code.isEmpty { return "\(cap)（颜色代码 \(code)）" }
        return cap
    }

    // MARK: - IPA 来源卡（云端下载 / 手动导入）

    /// 三条 IPA 来源：① 仓库云端下载 · ② 爱思云端下载 · ③ 手动导入（选文件，拷进缓存目录）.
    /// 两条云端**并存**、用户可选；各来源可用性**如实显示**（不可用给原因，不静默跳过）.
    /// 只显示缓存状态与入口，不做隐式下载 —— 安装按钮消费的就是这里落盘的 IPA.
    private var ipaSourceCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            Text("IPA 来源").font(AppFont.headline)

            sourceSelector

            if packStatuses.isEmpty {
                Text("尚未读取缓存状态.").font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                ForEach(packStatuses) { status in
                    HStack(spacing: 8) {
                        Text(status.pack.fileName)
                            .font(AppFont.subheadline.monospaced())
                        Spacer()
                        Text(ipaStatusText(status))
                            .font(AppFont.caption)
                            .foregroundStyle(status.cached ? AppTheme.success : .secondary)
                    }
                }
            }

            if downloading {
                ProgressView(value: downloadProgress).progressViewStyle(.linear)
                Text("正在下载… \(Int((downloadProgress * 100).rounded()))%")
                    .font(AppFont.numberSmall).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { Task { await downloadAllMissing() } } label: {
                    Text("下载").frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing || !selectedSourceHasAny)

                Button { showImporter = true } label: {
                    Text("手动导入").frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing)
            }

            if !selectedSourceHasAny && !packStatuses.isEmpty {
                Text("\(selectedSource.displayName)当前不可用：\(selectedSourceUnavailableReason)")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if packStatuses.contains(where: { $0.cached }) {
                Button("清理缓存") { clearCache() }
                    .font(AppFont.caption)
                    .foregroundStyle(AppTheme.danger)
                    .disabled(downloading || importing)
            }
            if let ipaMessage {
                Text(ipaMessage).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    /// 两条云端来源的**可用性 + 单选**（用户选从哪下）.
    /// 不可用来源置灰（显示原因），可选来源点一下即切换；每条来源行**下面**只读展示该来源的安装地址.
    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text("云端来源").font(AppFont.subheadlineEmphasis)
            ForEach(I4MobileInstallService.CloudSource.allCases) { source in
                let available = sourceAvailability(source).isAvailable
                VStack(alignment: .leading, spacing: 4) {
                    Button { selectedSource = source } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedSource == source ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedSource == source ? AppTheme.accent : AppTheme.unselected)
                                .appSymbol()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName).font(AppFont.subheadline).foregroundStyle(.primary)
                                Text(sourceAvailabilityText(source))
                                    .font(AppFont.caption)
                                    .foregroundStyle(available ? AppTheme.success : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)

                    sourceAddressLine(source)
                }
            }
        }
    }

    /// 来源的**安装地址**（只读展示 + 可点复制），显示在该来源行**下面**.
    ///
    /// 只读而非可编辑：见 `I4MobileInstallService.addressSummary(for:)` 的注释 ——
    /// 地址是编译期常量（仓库直链）/ 服务端按设备解析（爱思），做成可编辑而不被下载链路消费就是假配置.
    /// 复制按钮放在选择按钮**外面**（不能嵌进 `Button` 的 label —— 嵌套按钮点击会互相吞掉）.
    @ViewBuilder
    private func sourceAddressLine(_ source: I4MobileInstallService.CloudSource) -> some View {
        if let address = I4MobileInstallService.addressSummary(for: source) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sourceAddressLabel(source))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Text(address)
                    .font(AppFont.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    UIPasteboard.general.string = address
                    ipaMessage = "已复制 \(source.displayName) 的地址."
                } label: {
                    Image(systemName: "doc.on.doc").font(AppFont.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                Spacer(minLength: 0)
            }
            .padding(.leading, 30)   // 与来源选择圈对齐缩进
        }
    }

    /// 来源地址的前缀标签（仓库云端给目录前缀，爱思云端给接口端点）.
    private func sourceAddressLabel(_ source: I4MobileInstallService.CloudSource) -> String {
        switch source {
        case .warehouse: return "地址："
        case .i4: return "接口："
        }
    }

    /// 单个包的缓存状态文案（未缓存 / 已缓存 + 大小）.
    private func ipaStatusText(_ status: I4MobileInstallService.PackStatus) -> String {
        if status.cached { return "已缓存 \(status.bytes / 1024 / 1024) MB" }
        return status.availability(of: selectedSource).isAvailable ? "未下载" : "未下载 · 来源不可用"
    }

    /// 某来源对**全部包**的可用性：全部可用 ⇒ `.available`；否则 `.unavailable`（给原因）.
    private func sourceAvailability(_ source: I4MobileInstallService.CloudSource)
        -> I4MobileInstallService.CloudAvailability {
        guard !packStatuses.isEmpty else { return .unavailable(reason: "尚未读取缓存状态.") }
        let perPack = packStatuses.map { $0.availability(of: source) }
        if perPack.allSatisfy({ $0.isAvailable }) { return .available(detail: nil) }
        return .unavailable(reason: perPack.compactMap { $0.unavailableReason }.first ?? "部分包不可用.")
    }

    /// 来源可用性文案（供来源行显示）.
    private func sourceAvailabilityText(_ source: I4MobileInstallService.CloudSource) -> String {
        let availability = sourceAvailability(source)
        if availability.isAvailable { return "可用 · \(packStatuses.count) 个包." }
        return "不可用 · \(availability.unavailableReason ?? "不可用.")"
    }

    /// 当前选中来源是否至少有一个包可用（决定「下载」按钮可用性）.
    private var selectedSourceHasAny: Bool {
        packStatuses.contains { $0.availability(of: selectedSource).isAvailable }
    }

    /// 当前选中来源的不可用原因（供提示文案）.
    private var selectedSourceUnavailableReason: String {
        sourceAvailability(selectedSource).unavailableReason ?? "不可用."
    }

    /// 清理缓存目录里的 IPA（可再下载 / 再导入，故直接删）.
    private func clearCache() {
        for status in packStatuses where status.cached {
            try? I4MobileInstallService.removeCachedIPA(status.pack)
        }
        ipaMessage = "已清理缓存."
        refreshPackStatuses()
    }

    // MARK: - 下载管理入口（统一入口，照 I4StoreFreeView.downloadManagerSection 写法）

    /// 已下载安装包的**统一下载管理**入口（列表 + 安装 + 删除）.
    ///
    /// 照 `I4StoreFreeView.downloadManagerSection` 的写法（`NavigationLink` + `AppRowIcon` +
    /// 标题/副标题 + 数量徽标）；`IPADownloadManagerView()` 走**全量**（`filterSource == nil`，
    /// 即用户说的「那个统一的下载管理」，不按来源过滤）.
    ///
    /// 用 `NavigationLink`（子级 push）而**不是** `navigationDestination(isPresented:)`：
    /// 本页已在 `HomeView` 的 `NavigationStack` 里，再挂 `navigationDestination` 会让二级页丢返回箭头
    /// （见 `HomeView.swift` 该处注释）.
    private var downloadManagerCard: some View {
        NavigationLink {
            IPADownloadManagerView()
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "shippingbox.fill", tint: .blue,
                           symbolSize: 18, frameSize: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载管理").font(AppFont.subheadlineEmphasis).foregroundStyle(.primary)
                    Text("管理已下载的 IPA 并安装").font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if downloadedCount > 0 {
                    Text("\(downloadedCount)")
                        .font(AppFont.numberSmall)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(AppFont.captionEmphasis)
                    .foregroundStyle(.tertiary)
            }
            .padding(AppMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态区（尚未开始 / 正在安装 / 安装成功 / 安装未完成）

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            Text("安装状态").font(AppFont.headline)

            HStack(spacing: 10) {
                statusIcon
                Text(stageText)
                    .font(AppFont.subheadlineEmphasis)
                    .foregroundStyle(stageTint)
                Spacer()
                if case .installing = stage {
                    ProgressView().controlSize(.small)
                }
            }

            if installAction == nil {
                Text("本页未接入安装动作：安装服务（I4MobileInstallService）按爱思做法，"
                     + "用服务端现取的 sinf 覆盖包内再装，并在报告里写明用的是哪个账号的 sinf.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch stage {
        case .succeeded:
            Button { advancedShown = true } label: {
                Text("开启高级功能").frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
        case .installing:
            Button { } label: {
                Text("正在安装…").frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(true)
        default:
            Button { Task { await runInstall() } } label: {
                Text(isFailed ? "重试" : "开始安装").frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(installAction == nil)
        }
    }

    /// 当前是否处于失败态（用于按钮文案分支）.
    private var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    private var statusIcon: some View {
        Image(systemName: stageIconName)
            .font(AppFont.body)
            .foregroundStyle(stageTint)
            .appSymbol()
            .symbolEffect(.bounce, value: stage)
    }

    private var stageIconName: String {
        switch stage {
        case .idle: return "circle.dashed"
        case .installing: return "arrow.down.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var stageTint: Color {
        switch stage {
        case .idle: return .secondary
        case .installing: return AppTheme.accent
        case .succeeded: return AppTheme.success
        case .failed: return AppTheme.danger
        }
    }

    private var stageText: String {
        switch stage {
        case .idle: return "尚未开始"
        case .installing: return "正在安装…"
        case .succeeded: return "安装成功"
        case .failed(let message): return "安装未完成：\(message)"
        }
    }

    // MARK: - 数据与动作

    private func load() async {
        loading = true
        errorText = nil
        refreshPackStatuses()
        downloadedCount = IPADownloadLibrary.shared.items().count
        do {
            // collectFull 是阻塞调用（建 RSD 隧道 + 读 lockdown），放后台；非 Sendable 值经薄包装转移.
            let boxed = try await Task.detached(priority: .userInitiated) {
                I4MobileDeviceBox(value: try DeviceInfoService.collectFull())
            }.value
            info = boxed.value
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
        // 爱思云端可用性依赖本机 UDID（异步预热）：首屏先如实显示当前态，
        // 等身份预热完成后**再刷新一次**，让爱思云端从灰变可点（修本页「爱思云端无法点击」）.
        await warmUpI4Availability()
    }

    /// 等本机设备身份预热完成后刷新来源可用性（修「爱思云端一直灰着」）.
    ///
    /// 放在 `load()` 末尾、`loading = false` 之后：设备信息先出，再等身份就绪；
    /// 本方法挂在 `.task` 的结构化任务里，页面消失会随之取消（`warmUpDeviceIdentityForI4` 内部
    /// 用 `Task.isCancelled` 提前退出，不会空转）.
    private func warmUpI4Availability() async {
        let ready = await I4MobileInstallService.warmUpDeviceIdentityForI4()
        if ready { refreshPackStatuses() }
    }

    /// 刷新各包的缓存状态 + 两条云端可用性（只查本地文件 / 调用解析器，同步、廉价）.
    private func refreshPackStatuses() {
        packStatuses = I4MobileInstallService.packStatuses(resolver: i4Resolver)
    }

    /// 从**当前选中来源**下载所有「未缓存且该来源可用」的包，逐个汇报总进度.
    private func downloadAllMissing() async {
        downloading = true
        ipaMessage = nil
        downloadProgress = 0
        let source = selectedSource
        let missing = packStatuses.filter { !$0.cached && $0.availability(of: source).isAvailable }
        guard !missing.isEmpty else {
            ipaMessage = "没有需要下载的包（\(source.displayName)：未缓存且可用的包为空）."
            downloading = false
            return
        }
        do {
            for (idx, status) in missing.enumerated() {
                let count = missing.count
                try await I4MobileInstallService.downloadCloudIPA(
                    pack: status.pack,
                    from: source,
                    resolver: i4Resolver,
                    progress: { p in
                        // 进度回调来自后台下载线程：回主 actor 再改 @State.
                        Task { @MainActor in
                            downloadProgress = (Double(idx) + p) / Double(count)
                        }
                    },
                    onLog: { LoginLogger.shared.log($0, category: .i4Fix) })
            }
            ipaMessage = "下载完成."
        } catch {
            ipaMessage = "下载未完成：\(error.localizedDescription)"
        }
        refreshPackStatuses()
        downloading = false
    }

    /// 处理手动导入：`SharedDocumentPicker`（asCopy）已把文件拷进沙盒，直接认领并落缓存.
    private func importPicked(_ url: URL) async {
        importing = true
        ipaMessage = nil
        do {
            // 认领需读包内 Info.plist / 主二进制，放后台；返回值 `Pack` 是 Sendable.
            let pack = try await Task.detached(priority: .userInitiated) {
                try I4MobileInstallService.importIPA(
                    from: url,
                    onLog: { LoginLogger.shared.log($0, category: .i4Fix) })
            }.value
            ipaMessage = "已导入 \(pack.fileName)."
            refreshPackStatuses()
        } catch {
            ipaMessage = "导入未完成：\(error.localizedDescription)"
        }
        importing = false
    }

    private func runInstall() async {
        guard let installAction else { return }
        stage = .installing
        do {
            try await installAction()
            stage = .succeeded
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}
