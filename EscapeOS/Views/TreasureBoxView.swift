import SwiftUI

/// v0.3.207：百宝箱面板 —— 主页原生 sheet 呈现（presentationDetents 0.4↔1.0），
/// 系统上拉展开/下拉关闭，跟手流畅.内含杂七杂八工具的入口集合.
///
/// v0.3.328：**移除监督模式（Supervision）与 Wi-Fi 射频开关**。
/// - 监督模式：需要把设备置为受监督并自造 Escalate 身份，设备侧只认「当初监督它的那份身份」，
///   非越狱环境无解；已整块移除（含 SupervisionService）。
/// - Wi-Fi 射频：唯一可行通道是 MCInstall `SetWiFiPowerState`，而它**必须走监督通道**
///   （无监督 → 14005 `Unable to set Wi-Fi power`）。既然坚持不走监督那套，该开关已移除。
/// - 保留「局域网 Wi-Fi 配对连接」：走 lockdown `com.apple.mobile.wireless_lockdown`
///   `EnableWifiConnections`，无需监督、真实可用。
/// - 新增「开发者模式」：状态读 lockdown `DeveloperModeStatus`（com.apple.security.mac.amfi），
///   开启走 RSD amfi 服务；**系统未提供远程关闭接口**，关闭需去设备设置里手动关。
struct TreasureBoxView: View {
    /// v0.3.441：点「Gestalt 编辑」后的回调。由 HomeView 传入——它负责先关掉本 sheet，
    /// 再等 onDismiss 把 GestaltView push 到主页的导航栈上（本视图自己不 push，
    /// 因为在 sheet 里 push 会落到 sheet 自己那层导航栈，页面就没有返回按钮了）。
    let onOpenGestalt: () -> Void
    /// 打开「顽固图标清理」页。与 `onOpenGestalt` 同款：由 HomeView 在 sheet
    /// **完全关闭后**再 push（直接在本 sheet 里 push 会套第二层导航栈，页面没返回按钮）。
    let onOpenIconCleanup: () -> Void
    /// 打开「反激活设备」页.同样走「先关 sheet 再 push」的中转，理由同上.
    let onOpenDeactivate: () -> Void
    /// 打开「软件源管理」页.同样走「先关 sheet 再 push」的中转，理由同上.
    let onOpenSignSource: () -> Void
    /// 打开「爱思应用修复安装」页.同样走「先关 sheet 再 push」的中转，理由同上.
    let onOpenI4Fix: () -> Void
    /// 打开「安装爱思移动端」页.同样走「先关 sheet 再 push」的中转，理由同上.
    let onOpenMobileInstall: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题区（sheet 拖动指示条由 presentationDragIndicator 提供）
            // v0.3.208：拖动指示条与"百宝箱"文字挨太近 → 加 padding 撑开
            Text("百宝箱")
                .font(AppFont.headline)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: AppSpacing.row) {
                    heroCard
                    // v0.3.441：把「工具」卡提到设备控制卡**之前**。
                    // 为什么：本 sheet 默认 detent 只有 0.4，排在第三张的卡片在折叠区之外 ——
                    // 「Gestalt 编辑」这个**真实可点的入口**会看不见，得先上拉才找得到。
                    // 工具卡里是唯一能跳转的条目，优先级高于两个开关，故上移。
                    itemsCard
                    deviceControlCard
                }
                .padding(.horizontal, AppTheme.pageInset)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemBackground))
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            // 图标底改白色半透明圆角块（TRApp AppIcon 语言）：置于品牌深藏青渐变上对比清晰.
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .appSymbol()
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("百宝箱")
                    .font(AppFont.title3)
                    .foregroundStyle(.white)
                Text("小工具集 · 持续补充")
                    .font(AppFont.caption)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppTheme.brandGradient)
                // 右上角柔光（装饰，营造渐变纵深）.
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 180, height: 180)
                    .blur(radius: 48)
                    .offset(x: 110, y: -60)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    // MARK: - 设备控制

    /// 开发者模式（iDescriptor 同款数据源 + amfi 开启）
    @State private var devModeOn = false
    @State private var devModeUnknown = true     // true=读不到（隧道未连），显示未知而不是「已关闭」
    @State private var devModeBusy = false
    @State private var devModeMsg: String?
    @State private var devModeMsgIsError = false

    /// 局域网 Wi-Fi 配对连接（lockdown EnableWifiConnections，免监督）
    @State private var wifiPairingOn = false
    @State private var wifiPairingUnknown = true
    @State private var wifiPairingBusy = false
    @State private var wifiPairingMsg: String?
    @State private var wifiPairingMsgIsError = false

    private func refreshDeviceStates() {
        Task.detached(priority: .utility) {
            let dev = DeveloperModeService.status()
            let pairing = WirelessLockdownService.readWifiConnectionsEnabled()
            await MainActor.run {
                if let dev {
                    devModeOn = dev
                    devModeUnknown = false
                } else {
                    devModeUnknown = true
                }
                if let pairing {
                    wifiPairingOn = pairing
                    wifiPairingUnknown = false
                } else {
                    wifiPairingUnknown = true
                }
            }
        }
    }

    private func setDeveloperMode(_ on: Bool) {
        guard !devModeBusy else { return }
        // 关闭：系统没有远程接口（amfi 只有 reveal/enable/accept/status），如实说明并弹回
        guard on else {
            devModeMsgIsError = true
            devModeMsg = "开发者模式无法远程关闭，请在设备「设置 → 隐私与安全性 → 开发者模式」里关闭"
            return
        }
        devModeBusy = true
        devModeMsg = nil
        devModeMsgIsError = false
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try DeveloperModeService.enable() }
            catch { failure = error.localizedDescription }
            let errText = failure
            // 以设备读回为准
            let readBack = DeveloperModeService.status()
            await MainActor.run {
                devModeBusy = false
                if let errText {
                    devModeMsgIsError = true
                    devModeMsg = "失败：\(errText)"
                }
                if let readBack {
                    devModeOn = readBack
                    devModeUnknown = false
                }
                if errText == nil {
                    devModeMsgIsError = !(readBack ?? false)
                    devModeMsg = readBack == true
                        ? "开发者模式已开启"
                        : "已下发开启，设备可能要求在「设置 → 隐私与安全性 → 开发者模式」确认并重启后生效"
                }
            }
        }
    }

    private func setWifiPairing(_ on: Bool) {
        guard !wifiPairingBusy else { return }
        wifiPairingBusy = true
        wifiPairingMsg = nil
        wifiPairingMsgIsError = false
        Task.detached(priority: .userInitiated) {
            var confirmed: Bool?
            var failure: String?
            do {
                // 一次操作只建一条隧道：写入 + 读回在同一条隧道内完成
                confirmed = try WirelessLockdownService.setWifiConnections(enabled: on)
            } catch {
                failure = error.localizedDescription
            }
            let errText = failure
            let readBack = confirmed
            await MainActor.run {
                wifiPairingBusy = false
                if let errText {
                    wifiPairingMsgIsError = true
                    wifiPairingMsg = "失败：\(errText)"
                    return
                }
                if let readBack {
                    wifiPairingOn = readBack
                    wifiPairingUnknown = false
                    wifiPairingMsgIsError = readBack != on
                    wifiPairingMsg = readBack == on
                        ? "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接（设备已确认）"
                        : "写入已接受，但设备读回 \(readBack ? "开启" : "关闭")，可能被系统还原"
                } else {
                    wifiPairingOn = on
                    wifiPairingUnknown = false
                    wifiPairingMsgIsError = false
                    wifiPairingMsg = "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接（设备未回读确认）"
                }
            }
        }
    }

    private var deviceControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备控制").font(AppFont.headline).padding(.bottom, 2)

            Toggle(isOn: Binding(
                get: { devModeOn },
                set: { on in
                    guard !devModeBusy else { return }
                    setDeveloperMode(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("开发者模式", systemImage: "hammer").font(AppFont.subheadline)
                    Text(devModeUnknown
                         ? "状态未知（连接 LocalDevVPN + 配对文件后自动读取）"
                         : (devModeOn ? "已开启" : "已关闭 · 打开后设备可能要求重启"))
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(devModeBusy)

            Toggle(isOn: Binding(
                get: { wifiPairingOn },
                set: { on in
                    guard !wifiPairingBusy else { return }
                    setWifiPairing(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("局域网 Wi-Fi 配对连接", systemImage: "wifi").font(AppFont.subheadline)
                    Text(wifiPairingUnknown
                         ? "当前状态未知（连接 LocalDevVPN + 配对文件后自动读取）"
                         : "当前状态：\(wifiPairingOn ? "开启" : "关闭")")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(wifiPairingBusy)

            if devModeBusy || wifiPairingBusy {
                HStack { ProgressView().controlSize(.small); Text("正在执行…").font(AppFont.caption).foregroundStyle(.secondary) }
            }
            if let msg = devModeMsg {
                Text(msg)
                    .font(AppFont.caption)
                    .foregroundStyle(devModeMsgIsError ? AppTheme.danger : AppTheme.success)
            }
            if let msg = wifiPairingMsg {
                Text(msg)
                    .font(AppFont.caption)
                    .foregroundStyle(wifiPairingMsgIsError ? AppTheme.danger : AppTheme.success)
            }
        }
        .appCard()
        .onAppear(perform: refreshDeviceStates)
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.trAccent)
                    .appSymbol()
                Text("工具").font(AppFont.captionEmphasis).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)
            // v0.3.441：Gestalt 入口。样式与下方各行保持一致，右侧 chevron 表示「可进入」。
            Button {
                AppHaptics.tap()
                onOpenGestalt()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "gearshape.2.fill", tint: AppTheme.trAccent,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gestalt 编辑")
                            .font(AppFont.subheadline)
                        Text("查询 / 修改 MobileGestalt 键值（含备份）")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            Button {
                AppHaptics.tap()
                onOpenIconCleanup()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "trash.slash", tint: AppTheme.trRecoverable,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("顽固图标清理")
                            .font(AppFont.subheadline)
                        Text("删除装 App 失败残留的图标（含备份）")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            // 反激活设备：不可逆操作，安全闸（激活锁检测 + 不可跳过确认）在 ActivationView 里.
            // 图标用 `bolt.slash`（不用黄色感叹号，项目铁律）.
            Button {
                AppHaptics.tap()
                onOpenDeactivate()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "bolt.slash", tint: AppTheme.trDanger,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("反激活设备")
                            .font(AppFont.subheadline)
                        Text("让设备回到激活界面（不可逆，需先关查找）")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            // 软件源管理：添加 / 管理第三方软件源。进源列表页后，右上角另有「软件源下载管理」入口.
            Button {
                AppHaptics.tap()
                onOpenSignSource()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "shippingbox.circle.fill", tint: AppTheme.trAccent,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("软件源管理")
                            .font(AppFont.subheadline)
                        Text("添加 / 管理第三方软件源")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            // 爱思应用修复安装：把爱思 9.0 的「修复应用」入口移植过来.
            // 移植范围仅「经 AFC 写设备 i4tool2.acc + 读回校验」，不含联网授权，
            // 且与 App Store 加密包的 -42112 不同层（详见 I4AppFixView 顶部注释）.
            Button {
                AppHaptics.tap()
                onOpenI4Fix()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "bandage.fill", tint: AppTheme.trSuccess,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("爱思应用修复安装")
                            .font(AppFont.subheadline)
                        Text("重写爱思授权凭据 · 仅爱思源应用")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            // 安装爱思移动端：把爱思 9.0 的「安装爱思移动端」对话框移植过来.
            // 内嵌 IPA 是 FairPlay 加密包（cryptid=1），装前有诚实提示（见 I4MobileInstallView）.
            Button {
                AppHaptics.tap()
                onOpenMobileInstall()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "arrow.down.app.fill", tint: AppTheme.trAccent,
                               symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安装爱思移动端")
                            .font(AppFont.subheadline)
                        Text("爱思 9.0 移动端安装向导（加密包，可能装不上）")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.captionEmphasis)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .appCard()
    }
}
