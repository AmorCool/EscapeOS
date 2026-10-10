import SwiftUI

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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                deviceInfoCard
                statusCard
                disclaimerCard
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("安装爱思移动端")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.teal.opacity(0.12))
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("安装爱思移动端")
                    .font(.title3.weight(.semibold))
                Text("爱思 9.0 移动端安装向导")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 设备信息卡（机型 / 容量·颜色 / 序列号 / 系统版本）

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备信息").font(.headline)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取设备信息…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            } else if let info {
                infoRow("机型", info.deviceName ?? info.modelName)
                infoRow("容量 / 颜色", capacityColorText(info) ?? "未知")
                infoRow("序列号", info.serialNumber ?? "未知")
                infoRow("系统版本", "iOS \(info.systemVersion)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
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

    // MARK: - 状态区（尚未开始 / 正在安装 / 安装成功 / 安装未完成）

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安装状态").font(.headline)

            HStack(spacing: 10) {
                statusIcon
                Text(stageText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(stageTint)
                Spacer()
                if case .installing = stage {
                    ProgressView().controlSize(.small)
                }
            }

            if installAction == nil {
                Text("本页未接入安装动作：安装服务（I4MobileInstallService）按爱思做法，"
                     + "用服务端现取的 sinf 覆盖包内再装，并在报告里写明用的是哪个账号的 sinf.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
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
            .foregroundStyle(stageTint)
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

    // MARK: - 诚实说明（装之前的边界提示）

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("安装前须知", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.pending)

            bullet("「爱思移动端」是一组伪装成笔记/工具类的 iOS App（React Native 马甲包），"
                   + "官方不经 App Store 分发，必须由爱思 PC 端推送安装.")
            bullet("爱思 PC 端安装时不是直接用包内自带的 sinf，而是先往包里写入从 Apple 服务端现取的 sinf，"
                   + "再重打包安装.")
            bullet("包内自带的 sinf 属原始购买者（217 属「李 明」、220 属「小 敏」、"
                   + "photo 属「chongwei stven」），不是爱思共享账号；"
                   + "直接用会因本机未授权而装不上或启动闪退（-42112 一类）.")
            bullet("本服务只走一条路：向 NB 服务端现取 sinf 覆盖包内再装；取不到即明确报错，"
                   + "不回退到包内自带；每次用的账号会写进安装报告.")
            bullet("本页不含任何分发包内容，也不内置爱思的安装地址.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据与动作

    private func load() async {
        loading = true
        errorText = nil
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
