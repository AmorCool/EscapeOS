import SwiftUI

/// 「开启高级功能」独立入口页 —— 把爱思「开启高级功能」从「安装爱思移动端」对话框里
/// **拆出来**，做成百宝箱里的**独立功能入口**.
///
/// ## 为什么拆出来（用户原话）
/// 「爱思「开启高级功能」你没做好而且这个是单独一个功能」——
///   1. **没做好** ⇒ 原来只是弹一句「本应用尚未实现这一步」的窗，什么都没做。现在点它**真写**：
///      读设备身份 → 构造授权标记 plist → 经 house_arrest 写进载体 App 的 `Documents/` → 读回校验，
///      并把「哪一份文件写了、哪一份构造不出、为什么」逐条摆出来（引擎见 `I4PairingService`）。
///   2. **是单独一个功能** ⇒ 它有**独立入口**（百宝箱 → 「开启高级功能」），不再只藏在安装流程里。
///
/// ## 诚实边界（本页必须让用户看到，不假装能开）
/// 高级功能由设备端「爱思移动端」（`com.ownbook.notes` 等马甲包）起 VPN 提供，前提是往它沙盒写
/// **三份文件**。其中：
///   - **授权标记 `8es1421dg.be`**：本页「开启高级功能」按钮**真写**（读设备身份 → 构造 plist →
///     经 house_arrest 写进沙盒 → 读回校验）.
///   - **`pair.config`**：本页**另设**「尝试现场配对」按钮 —— 经 RSD 隧道连设备本机 `lockdownd`
///     发一次真 lockdown `Pair`，设备接受才拿得到记录。**成败以设备应答为准**，本页把设备返回的
///     **原始错误**如实摆出来，绝不把「请求已发出」说成「已配对」.
///   - **`RTD.cfg`**（PC 本地资源清单）：**造不出真值**，逐条说明.
/// ⇒ 设备端 VPN 起不起得来，取决于 `pair.config` 是否真的拿到；本页不弹「已开启」的假窗。
/// 逐条依据见 `I4PairingService` 文件头与 `P3_爱思助手_逆向/_简报/爱思9_配对与设备端Agent.md`.
///
/// ## 不内嵌第三方资源
/// 爱思 logo 是第三方商标，本页**不内嵌其图片资源**；顶部用 SF Symbol 圆角色块占位.
struct I4AdvancedView: View {

    /// 本页自有状态机（不硬编码展示文案）.
    private enum Stage: Equatable {
        case idle
        case probing
        case enabling
        case done
        case failed(String)
    }

    @State private var stage: Stage = .idle
    @State private var probe: I4PairingService.Probe?
    @State private var report: I4PairingService.Report?
    @State private var errorText: String?

    /// 「尝试现场配对」是否进行中（与「开启高级功能」各自的忙碌态互不干扰）.
    @State private var pairing = false
    /// 现场配对结果（成败都如实记录）.
    @State private var livePairReport: I4PairingService.LivePairReport?
    /// 现场配对的传输层失败（设备拒绝不算失败，走 `livePairReport.deviceError`）.
    @State private var livePairError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.section) {
                brandHeader
                prerequisiteCard
                if let probe {
                    carrierCard(probe)
                    filesCard(probe)
                } else if case .probing = stage {
                    probingCard
                }
                actionCard
                livePairCard
                if let report {
                    reportCard(report)
                }
                if let livePairReport {
                    livePairResultCard(livePairReport)
                }
                if let livePairError {
                    errorCard(livePairError)
                }
                if let errorText {
                    errorCard(errorText)
                }
            }
            .padding(AppTheme.pageInset)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("开启高级功能")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 头部

    private var brandHeader: some View {
        HStack(spacing: 14) {
            AppBrandTile(systemName: "lock.shield.fill", size: 56, symbolSize: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("开启高级功能").font(AppFont.title)
                Text("写设备端爱思移动端沙盒的配对 / 授权文件")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: - 前置条件

    private var prerequisiteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("前置条件").font(AppFont.headline)
            if let probe {
                statusRow(icon: probe.tunnelConnected ? "checkmark.circle.fill" : "xmark.circle.fill",
                          tint: probe.tunnelConnected ? AppTheme.trSuccess : AppTheme.trDanger,
                          title: "本地隧道",
                          detail: probe.tunnelConnected ? "已连接（LocalDevVPN）" : "未连接")
                statusRow(icon: probe.hasPairingFile ? "checkmark.circle.fill" : "xmark.circle.fill",
                          tint: probe.hasPairingFile ? AppTheme.trSuccess : AppTheme.trDanger,
                          title: "配对文件",
                          detail: probe.hasPairingFile ? "已导入（RSD 远程配对）" : "未导入")
            } else {
                Text("正在读取设备状态…").font(AppFont.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var probingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取设备已装列表与沙盒状态…")
                .font(AppFont.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .appCard()
    }

    // MARK: - 载体

    private func carrierCard(_ probe: I4PairingService.Probe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备端载体").font(AppFont.headline)
            if let carrier = probe.carrier {
                statusRow(icon: "app.badge.checkmark",
                          tint: AppTheme.trSuccess,
                          title: carrier.name,
                          detail: "\(carrier.bundleId)\(carrier.version.map { " · \($0)" } ?? "")")
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: carrier.hasContainer ? "folder.fill" : "folder.badge.questionmark")
                        .font(.system(size: 15))
                        .foregroundStyle(carrier.hasContainer ? AppTheme.accent : AppTheme.pending)
                        .frame(width: 22)
                    Text(carrier.hasContainer
                         ? "数据容器：\(carrier.containerPath)"
                         : "尚无数据容器（从未启动）；写入前会先启动它一次.")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if probe.candidates.count > 1 {
                    Text("另有 \(probe.candidates.count - 1) 个同家族马甲包也在设备上.")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
            } else {
                statusRow(icon: "xmark.circle.fill", tint: AppTheme.trDanger,
                          title: "未安装爱思移动端",
                          detail: "高级功能由该 App 提供，请先安装再回来.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - 三文件状态

    private func filesCard(_ probe: I4PairingService.Probe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配对 / 授权文件").font(AppFont.headline)
            if probe.files.isEmpty {
                Text("未选中载体，无法读取文件状态.")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                ForEach(probe.files) { file in
                    fileRow(file)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func fileRow(_ file: I4PairingService.PairFileStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: file.exists ? "doc.fill" : (file.constructible ? "doc.badge.plus" : "doc.badge.ellipsis"))
                    .font(.system(size: 15))
                    .foregroundStyle(file.exists ? AppTheme.trSuccess
                                     : (file.constructible ? AppTheme.accent : AppTheme.pending))
                    .frame(width: 22)
                Text(file.name).font(AppFont.subheadlineEmphasis)
                Text(file.kind).font(AppFont.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(file.exists ? (file.bytes.map { "\($0) B" } ?? "存在") : "不存在")
                    .font(AppFont.numberSmall)
                    .foregroundStyle(file.exists ? AppTheme.trSuccess : .secondary)
            }
            Text(fileDescription(file))
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)
        }
        .padding(.vertical, 2)
    }

    /// 文件行的说明文案：有运行时前提（`note`）时优先显示它，其次才是可构造 / 不可构造.
    private func fileDescription(_ file: I4PairingService.PairFileStatus) -> String {
        if let note = file.note { return note }
        if file.constructible {
            return file.exists ? "已在设备沙盒中；可重新写入覆盖." : "本应用可构造并写入此文件."
        }
        return "无法构造：" + (file.reason ?? "")
    }

    // MARK: - 动作

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                AppHaptics.tap()
                Task { await runEnable() }
            } label: {
                HStack(spacing: 6) {
                    if case .enabling = stage { ProgressView().controlSize(.small) }
                    Text(buttonTitle).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button))
            .disabled(isBusy || probe?.carrier == nil)

            Text("把授权标记（8es1421dg.be，内容 = i4tool2.acc 的 auth plist）写进载体 App 的 Documents，"
                 + "并读回校验。pair.config 需另走「尝试现场配对」一步，RTD.cfg 无法构造，"
                 + "会在结果里逐条说明.")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var buttonTitle: String {
        switch stage {
        case .enabling: return "正在写入…"
        case .done: return "重新写入"
        default: return "开启高级功能"
        }
    }

    private var isBusy: Bool {
        switch stage {
        case .probing, .enabling: return true
        default: return false
        }
    }

    // MARK: - 现场配对（路径 A）

    private var livePairCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("现场配对").font(AppFont.headline)
            Button {
                AppHaptics.tap()
                Task { await runLivePair() }
            } label: {
                HStack(spacing: 6) {
                    if pairing { ProgressView().controlSize(.small) }
                    Text(pairing ? "正在配对…" : "尝试现场配对").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button))
            .disabled(pairing || probe?.hasPairingFile != true)

            Text("经 RSD 隧道连设备本机的 lockdownd，发一次真 lockdown Pair；"
                 + "设备接受才拿得到配对记录（pair.config），再写进载体 App 的 Documents"
                 + "成败以设备应答为准，结果里会如实给出设备返回的原始错误.")
                .font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func livePairResultCard(_ report: I4PairingService.LivePairReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: report.paired ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(report.paired ? AppTheme.trSuccess : AppTheme.trDanger)
                    .appSymbol()
                Text("现场配对结果").font(AppFont.headline)
                Spacer(minLength: 0)
            }
            Text(report.detail)
                .font(AppFont.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let bytes = report.pairConfigBytes {
                detailLine("配对记录", "\(bytes) B")
            }
            if let carrier = report.wroteToCarrier {
                detailLine("已写入", "\(carrier)/Documents/\(I4PairingService.pairConfigName)")
            }
            detailLine("写后读回", report.verified ? "一致" : "未校验")

            if let deviceError = report.deviceError {
                VStack(alignment: .leading, spacing: 2) {
                    Text("设备返回的错误").font(AppFont.captionEmphasis).foregroundStyle(AppTheme.trDanger)
                    Text(deviceError).font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - 结果

    private func reportCard(_ report: I4PairingService.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: report.verified.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(report.verified.isEmpty ? AppTheme.pending : AppTheme.trSuccess)
                    .appSymbol()
                Text("结果").font(AppFont.headline)
                Spacer(minLength: 0)
            }
            Text(report.verdict)
                .font(AppFont.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !report.wrote.isEmpty {
                detailLine("已写入", report.wrote.joined(separator: ", "))
            }
            if !report.verified.isEmpty {
                detailLine("读回一致", report.verified.joined(separator: ", "))
            }
            ForEach(report.notConstructed, id: \.name) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("未写入：\(item.name)").font(AppFont.captionEmphasis).foregroundStyle(AppTheme.pending)
                    Text(item.reason).font(AppFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(report.warnings, id: \.self) { warning in
                Text("注意：\(warning)").font(AppFont.caption).foregroundStyle(AppTheme.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 14))
                    .foregroundStyle(AppTheme.trDanger).appSymbol()
                Text("未完成").font(AppFont.headline)
                Spacer(minLength: 0)
            }
            Text(text).font(AppFont.subheadline).foregroundStyle(AppTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - 通用件

    private func statusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.subheadlineEmphasis)
                Text(detail).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(AppFont.captionEmphasis).foregroundStyle(.secondary)
            Text(value).font(AppFont.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作实现

    private func load() async {
        stage = .probing
        errorText = nil
        let result = await I4PairingService.probe()
        probe = result
        if let error = result.error {
            errorText = error
            stage = .failed(error)
        } else {
            stage = .idle
        }
    }

    private func runEnable() async {
        stage = .enabling
        errorText = nil
        report = nil
        do {
            let result = try await I4PairingService.enable()
            report = result
            stage = .done
            AppHaptics.success()
        } catch {
            errorText = error.localizedDescription
            stage = .failed(error.localizedDescription)
            AppHaptics.error()
        }
        // 无论成败，刷新一次沙盒状态（让文件行反映真实结果）.
        let refreshed = await I4PairingService.probe()
        probe = refreshed
    }

    private func runLivePair() async {
        pairing = true
        livePairReport = nil
        livePairError = nil
        do {
            let result = try await I4PairingService.attemptLockdownPair()
            livePairReport = result
            if result.paired { AppHaptics.success() } else { AppHaptics.error() }
        } catch {
            // 传输层失败（建隧道 / 连 lockdownd / 序列化）才算「未完成」；设备拒绝走结果卡.
            livePairError = error.localizedDescription
            AppHaptics.error()
        }
        pairing = false
        // 无论成败，刷新一次沙盒状态（pair.config 可能已写入）.
        let refreshed = await I4PairingService.probe()
        probe = refreshed
    }
}
