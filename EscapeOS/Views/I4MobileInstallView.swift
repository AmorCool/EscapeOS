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

    /// IPA 来源区（仓库云端下载 / 自定义包体 / 手动导入）：各包缓存状态 + 下载进度 + 导入选择器.
    @State private var packStatuses: [I4MobileInstallService.PackStatus] = []
    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var importing = false
    @State private var showImporter = false
    @State private var ipaMessage: String?
    /// 自定义包体输入框内容（IPA 直链）.
    @State private var customURLText = ""
    /// 正在安装的包体 id（用于禁用该行安装按钮；`nil` = 空闲）.
    @State private var installingPackId: String?
    /// 已下载 IPA 数量（下载管理入口的数量徽标；进页面时读一次磁盘台账）.
    @State private var downloadedCount = 0
    /// 本机推荐（移植爱思瀑布自动选包的结果；`nil` = 设备信息不可用，未算出）.
    @State private var autoPick: I4MobileInstallService.AutoPick?
    /// 是否正在识别本机（读已装列表）并选包.
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.section) {
                heroCard
                deviceInfoCard
                autoPickCard
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

    // MARK: - 本机推荐卡（移植爱思「按 iOS 版本瀑布降级选包」）

    /// 本机推荐：按爱思的瀑布顺序（⓪①②③④⑤）给出一个**软推荐**包体 ——
    /// 只高亮/给一个默认入口，**不强制**；用户仍可在下方 IPA 来源里手动选别的包.
    ///
    /// 诚实边界：本仓内置只有 `220` / `217`；`305` / `213` / `723` 无包体 ⇒ 命中时如实回落，
    /// 全部落空时显示「无可用包体」并附逐档轨迹（说明为什么落不到包体）.
    private var autoPickCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            Text("本机推荐").font(AppFont.headline)

            if picking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在识别本机并选包…").font(AppFont.caption).foregroundStyle(.secondary)
                }
            } else if let autoPick {
                autoPickContent(autoPick)
            } else {
                Text("设备信息不可用，无法给出本机推荐；可在下方 IPA 来源手动选择包体.")
                    .font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    /// 本机推荐的内容：推荐包体（或「无可用包体」）+ 依据 + 逐档轨迹 + 一键下载并安装.
    @ViewBuilder
    private func autoPickContent(_ pick: I4MobileInstallService.AutoPick) -> some View {
        if let pack = pick.pack {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(AppFont.body)
                    .foregroundStyle(AppTheme.accent)
                    .appSymbol()
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(pack.fileName) · \(pack.expectedBundleId) \(pack.expectedVersion)")
                        .font(AppFont.subheadlineEmphasis)
                    Text("依据：\(pick.tier.basis).")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
            }

            if installAction != nil {
                if I4MobileInstallService.isCached(pack) {
                    Button { Task { await installPack(pack) } } label: {
                        Text("安装推荐包").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle())
                    .disabled(installingPackId != nil || downloading || importing)
                } else {
                    Button { Task { await downloadAndInstall(pack) } } label: {
                        Text("下载并安装推荐包").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle())
                    .disabled(downloading || importing || installingPackId != nil)
                }
            }
        } else {
            Text("本机推荐：无可用包体.")
                .font(AppFont.subheadlineEmphasis)
                .foregroundStyle(AppTheme.danger)
            Text("依据：\(pick.tier.basis).")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }

        if pick.alreadyInstalledMain {
            Text("本机已装 com.ownbook.notes：按爱思做法不再优先选高版本包体.")
                .font(AppFont.caption).foregroundStyle(AppTheme.success)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(pick.trace, id: \.self) { line in
            Text(line)
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - IPA 来源卡（仓库云端 / 自定义包体 / 手动导入）

    /// IPA 来源：① 仓库云端（内置三包 + 用户自定义包体，逐个可下载 / 可安装）· ② 手动导入.
    /// 各包可用性**如实显示**（不可用给原因，不静默跳过）；只显示缓存状态与入口，不做隐式下载 ——
    /// 安装消费的就是这里落盘的 IPA.
    private var ipaSourceCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.row) {
            Text("IPA 来源").font(AppFont.headline)

            warehouseSourceLine

            if packStatuses.isEmpty {
                Text("尚未读取缓存状态.").font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                ForEach(packStatuses) { status in
                    packRow(status)
                }
            }

            customPackEntry

            if downloading {
                ProgressView(value: downloadProgress).progressViewStyle(.linear)
                Text("正在下载… \(Int((downloadProgress * 100).rounded()))%")
                    .font(AppFont.numberSmall).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { Task { await downloadAllMissing() } } label: {
                    Text("下载全部").frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing || !hasAnyDownloadable)

                Button { showImporter = true } label: {
                    Text("手动导入").frame(maxWidth: .infinity)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing)
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

    /// 仓库云端的**下载地址**（只读展示 + 可点复制）—— 内置包直链同处一个 Release 目录.
    ///
    /// 只读而非可编辑：地址是编译期常量（`Pack.cloudURL`），做成可编辑而不被下载链路消费就是假配置；
    /// 用户要指定自己的 IPA，走下方「自定义包体」入口.
    @ViewBuilder
    private var warehouseSourceLine: some View {
        if let address = I4MobileInstallService.addressSummary(for: .warehouse) {
            VStack(alignment: .leading, spacing: 4) {
                Text("仓库云端").font(AppFont.subheadlineEmphasis)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("地址：").font(AppFont.caption).foregroundStyle(.secondary)
                    Text(address)
                        .font(AppFont.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = address
                        ipaMessage = "已复制仓库云端的地址."
                    } label: {
                        Image(systemName: "doc.on.doc").font(AppFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 单个包体行：文件名 + 缓存状态 + 单独「下载」/「安装」+（自定义包体可移除）.
    @ViewBuilder
    private func packRow(_ status: I4MobileInstallService.PackStatus) -> some View {
        let pack = status.pack
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(pack.fileName).font(AppFont.subheadline.monospaced())
                    if isRecommended(pack) {
                        Text("推荐").font(AppFont.caption).foregroundStyle(AppTheme.accent)
                    }
                }
                Text(ipaStatusText(status))
                    .font(AppFont.caption)
                    .foregroundStyle(status.cached ? AppTheme.success : .secondary)
            }
            Spacer(minLength: 6)
            if status.cached {
                if installAction != nil {
                    Button { Task { await installPack(pack) } } label: {
                        Text("安装").font(AppFont.caption)
                    }
                    .buttonStyle(TintedButtonStyle())
                    .disabled(installingPackId != nil || downloading)
                }
            } else if status.warehouseAvailability.isAvailable {
                Button { Task { await downloadPack(pack) } } label: {
                    Text("下载").font(AppFont.caption)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing)
            }
            if pack.isCustom {
                Button { removeCustom(pack) } label: {
                    Image(systemName: "trash").font(AppFont.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.danger)
                .disabled(downloading || importing || installingPackId != nil)
            }
        }
    }

    /// 「自定义包体」入口：填任意 IPA 直链 ⇒ 加入列表 ⇒ 走同一下载链路 ⇒ 逐个可安装.
    private var customPackEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自定义包体").font(AppFont.subheadlineEmphasis)
            Text("填入任意 IPA 直链（http / https），下载后按同一安装链路安装.")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://example.com/app.ipa", text: $customURLText)
                    .font(AppFont.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    customURLText = UIPasteboard.general.string ?? ""
                } label: {
                    Text("粘贴").font(AppFont.caption)
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(downloading || importing)
            }
            Button { Task { await addCustom() } } label: {
                Text("添加并下载").frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(downloading || importing
                      || customURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 单个包的缓存状态文案（未缓存 / 已缓存 + 大小）.
    private func ipaStatusText(_ status: I4MobileInstallService.PackStatus) -> String {
        if status.cached { return "已缓存 \(status.bytes / 1024 / 1024) MB" }
        return status.warehouseAvailability.isAvailable ? "未下载" : "未下载 · 来源不可用"
    }

    /// 是否至少有一个包可下载（决定「下载全部」按钮可用性）.
    private var hasAnyDownloadable: Bool {
        packStatuses.contains { !$0.cached && $0.warehouseAvailability.isAvailable }
    }

    /// 该包是否是本机推荐（用于在包体行加「推荐」标记）.
    private func isRecommended(_ pack: I4MobileInstallService.Pack) -> Bool {
        autoPick?.pack?.fileName == pack.fileName
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
            await refreshAutoPick()
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    /// 刷新各包（内置 + 自定义）的缓存状态 + 仓库云端可用性（只查本地文件，同步、廉价）.
    private func refreshPackStatuses() {
        packStatuses = I4MobileInstallService.packStatuses()
    }

    /// 读设备已装列表并按爱思瀑布算本机推荐（best-effort：设备信息缺失时给出「无法推荐」）.
    ///
    /// iOS 版本 / 机型直接取已读到的 `DeviceInfoModel`（`systemVersion` / `productType`），
    /// 只补一次「已装列表」（阻塞的隧道读，放后台，见 `deviceProfile`）.
    private func refreshAutoPick() async {
        guard let info else { autoPick = nil; return }
        picking = true
        let profile = await I4MobileInstallService.deviceProfile(
            iosVersion: info.systemVersion, model: info.productType)
        autoPick = I4MobileInstallService.autoPick(profile: profile)
        picking = false
    }

    /// 从**仓库云端**下载所有「未缓存且可用」的包，逐个汇报总进度.
    private func downloadAllMissing() async {
        downloading = true
        ipaMessage = nil
        downloadProgress = 0
        let missing = packStatuses.filter { !$0.cached && $0.warehouseAvailability.isAvailable }
        guard !missing.isEmpty else {
            ipaMessage = "没有需要下载的包（未缓存且可用的包为空）."
            downloading = false
            return
        }
        do {
            for (idx, status) in missing.enumerated() {
                let count = missing.count
                try await I4MobileInstallService.downloadCloudIPA(
                    pack: status.pack,
                    from: .warehouse,
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

    /// 下载**单个**包（内置包 / 自定义包体共用）；自定义包体下载后再校验确为 IPA，不合规即删残包.
    private func downloadPack(_ pack: I4MobileInstallService.Pack) async {
        downloading = true
        ipaMessage = nil
        downloadProgress = 0
        do {
            try await I4MobileInstallService.downloadCloudIPA(
                pack: pack,
                from: .warehouse,
                progress: { p in
                    Task { @MainActor in downloadProgress = p }
                },
                onLog: { LoginLogger.shared.log($0, category: .i4Fix) })
            if pack.isCustom {
                // 校验读包（解 Info.plist），放后台；返回 (bundleId, version) 是 Sendable.
                let info = try await Task.detached(priority: .userInitiated) {
                    try I4MobileInstallService.verifyCachedIPA(pack)
                }.value
                ipaMessage = "已下载 \(pack.fileName)（\(info.bundleId)）."
            } else {
                ipaMessage = "已下载 \(pack.fileName)."
            }
        } catch {
            // 自定义包体校验不过：删掉残包，避免留下不可安装的文件.
            if pack.isCustom { try? I4MobileInstallService.removeCachedIPA(pack) }
            ipaMessage = "下载未完成：\(error.localizedDescription)"
        }
        refreshPackStatuses()
        downloading = false
    }

    /// 「下载并安装」本机推荐包：先下（未缓存时）再装（走既有 sinf 链路）；任一步失败即止.
    private func downloadAndInstall(_ pack: I4MobileInstallService.Pack) async {
        if !I4MobileInstallService.isCached(pack) {
            await downloadPack(pack)
            guard I4MobileInstallService.isCached(pack) else { return }
        }
        await installPack(pack)
    }

    /// 加入并下载一个自定义包体（填的 IPA 直链）；校验失败如实报错，不加入.
    private func addCustom() async {
        let pack: I4MobileInstallService.Pack
        do {
            pack = try I4MobileInstallService.addCustomPack(urlString: customURLText)
        } catch {
            ipaMessage = "添加失败：\(error.localizedDescription)"
            return
        }
        customURLText = ""
        refreshPackStatuses()
        if I4MobileInstallService.isCached(pack) {
            ipaMessage = "\(pack.fileName) 已在缓存，可直接安装."
            return
        }
        await downloadPack(pack)
    }

    /// 移除一个自定义包体（含其缓存文件）.
    private func removeCustom(_ pack: I4MobileInstallService.Pack) {
        do {
            try I4MobileInstallService.removeCustomPack(pack)
            ipaMessage = "已移除 \(pack.fileName)."
        } catch {
            ipaMessage = "移除失败：\(error.localizedDescription)"
        }
        refreshPackStatuses()
    }

    /// 安装**单个**包（走既有 sinf 链路：服务端现取 sinf → 覆盖包内 → 装副本）.
    private func installPack(_ pack: I4MobileInstallService.Pack) async {
        installingPackId = pack.id
        stage = .installing
        do {
            _ = try await I4MobileInstallService.install(
                pack: pack,
                onLog: { LoginLogger.shared.log($0, category: .i4Fix) })
            stage = .succeeded
        } catch {
            stage = .failed(error.localizedDescription)
        }
        installingPackId = nil
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
