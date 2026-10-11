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
            // 顶部标题区：v0.3.xxx 起标题改由页内 `brandHeader` 承担（不再是固定居中标题 +
            // 全宽渐变 banner 两处重复）。sheet 拖动指示条由 presentationDragIndicator 提供。
            ScrollView {
                VStack(spacing: AppSpacing.row) {
                    brandHeader
                        .padding(.horizontal, AppTheme.pageInset)
                    // v0.3.441：把「工具」区提到设备控制卡**之前**。
                    // 为什么：本 sheet 默认 detent 只有 0.4，排在第三张的卡片在折叠区之外 ——
                    // 「Gestalt 编辑」这个**真实可点的入口**会看不见，得先上拉才找得到。
                    // 工具区里是唯一能跳转的条目，优先级高于两个开关，故上移。
                    // 工具区改用「全宽行 + 发丝分隔」（`AppSettingsRow` + `AppHairline`，
                    // 见 `DesignSystem.swift` 硬规则 5），故**不套** `pageInset` —— 行内自带
                    // `AppSpacing.settingsInset`(22) 边距、分隔线全宽，与 TRApp 设置列表一致.
                    itemsCard
                    deviceControlCard
                        .padding(.horizontal, AppTheme.pageInset)
                }
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemBackground))
    }

    /// 页面头部：品牌图标块 + 标题 + 副标题（**不是全宽方块 banner**）。
    ///
    /// v0.3.xxx：用户反馈「banner 是方块状的，不喜欢这种方块」⇒ 去掉全宽深藏青渐变实心 banner，
    /// 深色品牌色只保留在**紧凑的连续圆角图标块**（`AppBrandTile`）里，标题 / 副标题走页面背景上的
    /// 主 / 次字色。对照 TRApp（设置页无 hero、直接大标题 + 卡片分组；欢迎页 App 图标是深色大圆角方块）。
    private var brandHeader: some View {
        HStack(spacing: 14) {
            AppBrandTile(systemName: "shippingbox.and.arrow.backward.fill", size: 56, symbolSize: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("百宝箱")
                    .font(AppFont.title)
                Text("小工具集 · 持续补充")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
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

    /// 工具入口区。改用 DesignSystem 的**全宽行 + 发丝分隔**语言（`AppSettingsRow` + `AppHairline`，
    /// 见 `DesignSystem.swift` 硬规则 5）—— 原先是 16 圆角卡片（`.appCard()`）+ 手写行 + `Divider()`，
    /// 与本仓设置列表规范不符. 行内自带 `AppSpacing.settingsInset`(22) 边距与行底发丝分隔，
    /// 故本区**不套** `pageInset`（分隔线全宽），仅分组标题单独加 `pageInset` 与卡片左缘对齐；
    /// 标题与首行之间另加一条全宽 `AppHairline` 作组首规则.
    ///
    /// ⚠️ `AppSettingsRow` 图标恒用 `AppTheme.accent`（systemBlue），**不接**行级 tint ⇒ 原先
    /// `trRecoverable` / `trDanger` / `trSuccess` 的语义着色统一为 accent（TRApp 设置行即单色图标）.
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
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.bottom, 6)
            // 组首规则：本组已脱离卡片、直接落在页面背景上，用一条全宽发丝分隔界定分组起点
            // （与各行行底分隔同一语言；`AppHairline` 的独立调用点，不再只被 `AppSettingsRow` 内部引用）.
            AppHairline()
            // v0.3.441：Gestalt 入口。右侧 chevron 表示「可进入」.
            AppSettingsRow(icon: "gearshape.2.fill", title: "Gestalt 编辑",
                           keywords: ["查询 / 修改 MobileGestalt 键值（含备份）"]) {
                AppHaptics.tap()
                onOpenGestalt()
            }
            AppSettingsRow(icon: "trash.slash", title: "顽固图标清理",
                           keywords: ["删除装 App 失败残留的图标（含备份）"]) {
                AppHaptics.tap()
                onOpenIconCleanup()
            }
            // 反激活设备：不可逆操作，安全闸（激活锁检测 + 不可跳过确认）在 ActivationView 里.
            // 图标用 `bolt.slash`（不用黄色感叹号，项目铁律）.
            AppSettingsRow(icon: "bolt.slash", title: "反激活设备",
                           keywords: ["让设备回到激活界面（不可逆，需先关查找）"]) {
                AppHaptics.tap()
                onOpenDeactivate()
            }
            // 软件源管理：添加 / 管理第三方软件源。进源列表页后，右上角另有「软件源下载管理」入口.
            AppSettingsRow(icon: "shippingbox.circle.fill", title: "软件源管理",
                           keywords: ["添加 / 管理第三方软件源"]) {
                AppHaptics.tap()
                onOpenSignSource()
            }
            // 爱思应用修复安装：把爱思 9.0 的「修复应用」入口移植过来.
            // 设备级一键修复（照爱思：无应用选择、无台账），经 AFC 写设备 i4tool2.acc + 读回校验，
            // 不含联网授权（详见 I4AppFixView 顶部注释）.
            AppSettingsRow(icon: "bandage.fill", title: "爱思应用修复安装",
                           keywords: ["重写爱思授权凭据 · 仅爱思源应用"]) {
                AppHaptics.tap()
                onOpenI4Fix()
            }
            // 安装爱思移动端：把爱思 9.0 的「安装爱思移动端」对话框移植过来.
            // 内嵌 IPA 是 FairPlay 加密包（cryptid=1），装前有诚实提示（见 I4MobileInstallView）.
            // 末行不附发丝分隔（组尾）.
            AppSettingsRow(icon: "arrow.down.app.fill", title: "安装爱思移动端",
                           keywords: ["爱思 9.0 移动端安装向导（加密包，可能装不上）"],
                           showsSeparator: false) {
                AppHaptics.tap()
                onOpenMobileInstall()
            }
        }
    }
}
