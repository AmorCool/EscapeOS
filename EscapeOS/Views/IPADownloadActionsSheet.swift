import SwiftUI
import UIKit

/// v0.3.378：已下载 IPA 的操作面板 —— 「下载管理」点任意一行弹出。
///
/// 动作对齐 NB 全能助手：覆盖安装 / 在线安装 / 打开 / 复制商店链接 / 分享 / 删除 / 取消。
/// 视觉沿用虚拟定位页的液态玻璃卡片（`locusGlass`）+ `AppRowIcon` 图标基调。
///
/// **全部复用既有实现，不另起炉灶**：
/// · 覆盖安装 → 下载中心 `installLocal`（→ `AppStoreInstallService.installLocalIPA`）
/// · 打开     → `JITEnableService.launchApp(bundleID:)`
/// · 分享     → `ShareSheet`（`UIActivityViewController` 包装）
/// · 复制商店链接 → 读包内 `iTunesMetadata.plist` 的 `itemId` 拼 **App Store 商店链接**（纯读本地文件，零网络零服务）
/// · 提取下载链接 → 台账 `IPADownloadItem.sourceURL`（**下载时就落盘**的 **IPA 包原链接**，纯读本地数据，零网络零服务）
///   「下载中」的任务还没有台账行 → 列表把该任务的 `Job.remoteURL` 放进 `item.sourceURL` 带进来
/// · 复制     → `UIPasteboard.general.string`
/// · 提示     → `ToastCenter.shared.show`
struct IPADownloadActionsSheet: View {

    /// 目标条目
    let item: IPADownloadItem
    /// 列表已解析好的图标地址（台账里可能没有，由列表按 bundleId 反查补齐）
    let iconURL: String?
    /// 覆盖安装（走既有的本地安装链路）
    let onOverwriteInstall: () -> Void
    /// 删除（删文件 + 删台账，列表侧负责刷新与提示）
    let onDelete: () -> Void

    /// v0.3.387：「下载中」任务弹这个面板时为 true。
    ///
    /// v0.3.394 改法（用户参考图是「点一行 → 展开这个包的详情」）：**不再裁剪行**，
    /// 全部动作照原样渲染，只把**需要本地包文件**的两行使灰 —— 「覆盖安装」「在线安装」。
    /// 其余照常：「提取下载链接」用任务直链、「复制商店链接」用台账商品号、
    /// 打开/分享/删除在真缺文件时会给出各自的提示（不再是「点下去没反应」）。
    /// 已下载条目走原样（默认 false）。
    var isPendingDownload: Bool = false

    @Environment(\.dismiss) private var dismiss

    /// 「打开」是否可用 —— 必须设备上真的装了才给点
    private enum OpenState { case checking, installed, missing }
    @State private var openState: OpenState = .checking

    @State private var shareTarget: ShareTarget?
    @State private var showDeleteConfirm = false

    // MARK: - 行模型

    private enum RowTrailing {
        case none
        case text(String)
        case progress
    }

    private struct RowSpec {
        let icon: String
        let tint: Color
        let title: String
        var titleTint: Color = .primary
        var trailing: RowTrailing = .none
        var disabled: Bool = false
        let action: () -> Void
    }

    /// 台账里真实存在的来源直链 = 「**提取下载链接**」的取值（IPA 包原链接，下载时回填）。
    /// **只给「提取下载链接」用**：「复制商店链接」的取值完全另算（包内 `iTunesMetadata.itemId`）。
    private var sourceLink: String? {
        guard let raw = item.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
        return raw
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                cardSection("安装", rows: installRows)

                cardSection("操作", rows: actionRows)

                cardSection("其它操作", rows: otherRows)

                cancelButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 26)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .toastHost()
        .sheet(item: $shareTarget) { ShareSheet(items: [$0.url]) }
        .confirmationDialog("删除这个安装包？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .task { await resolveOpenState() }
    }

    // MARK: - 头部包信息

    private var header: some View {
        HStack(spacing: 12) {
            headerIcon

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    // 换行、不省略
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let v = item.version, !v.isEmpty { chip("v\(v)", .blue) }
                    chip(item.sizeText, .green)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let s = iconURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: monogram
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            monogram
        }
    }

    private var monogram: some View {
        let source = item.title.isEmpty ? (item.bundleId ?? "") : item.title
        let letter = String(source.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.blue.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: 48, height: 48)
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }

    // MARK: - 动作行

    /// 安装：覆盖安装（原来的本地安装方式）+ 在线安装
    ///
    /// v0.3.394：「下载中」的任务**把这两行置灰**（右侧标「下载中」）——
    /// 本地还没有包文件，覆盖安装必然落到 `installLocal` 的「文件不存在」分支，
    /// 而那条分支会给**这个文件名**记一条失败（`recordFileFailure`），
    /// 之后真正下好的同名条目就会被标成红色「下载失败」（v0.3.390 专门修过这个坑）。
    /// 在线安装同样不该在包还没落地时另起一次。所以这两行只在有本地文件时可点。
    private var installRows: [RowSpec] {
        [
            RowSpec(icon: "arrow.down.app.fill", tint: .blue, title: "覆盖安装",
                    trailing: isPendingDownload ? .text("下载中") : RowTrailing.none,
                    disabled: isPendingDownload) {
                onOverwriteInstall()
                dismiss()
            },
            onlineInstallRow
        ]
    }

    /// 「在线安装」行。两条置灰规则：
    /// 1. **v0.3.394**：下载中的任务（本地还没有包）→ 灰 + 「下载中」（理由见 `installRows`）；
    /// 2. 本机服务器当前被 `.share` 会话占用时不可点
    ///    （单例 server 一次只服务一份文件，再 `start()` 会先 `stop()` 掉那份会话）。
    /// ⚠️ v0.3.386 起「提取下载链接」已改为纯读台账、不再起本机服务 →
    /// `blockedByShare` **恒为 `false`**（判断有意保留，见 `IPALocalHTTPServer` 类型注释）。
    private var onlineInstallRow: RowSpec {
        if !OnlineInstallService.isImplemented {
            return RowSpec(icon: "icloud.and.arrow.down", tint: .green, title: "在线安装",
                           trailing: .text("未接入")) {
                onlineInstall()
            }
        }
        let blockedByShare = IPALocalHTTPServer.shared.currentPurpose == .share
        let note: String? = isPendingDownload ? "下载中" : (blockedByShare ? "分享中" : nil)
        return RowSpec(icon: "icloud.and.arrow.down", tint: .green, title: "在线安装",
                       trailing: note.map { RowTrailing.text($0) } ?? RowTrailing.none,
                       disabled: isPendingDownload || blockedByShare) {
            onlineInstall()
        }
    }

    private var actionRows: [RowSpec] {
        var rows: [RowSpec] = [openRow]
        // 「复制商店链接」**常显**：取值**台账商品号优先**（`item.storeItemId`），
        // 读包内 `iTunesMetadata.itemId` 只是兜底 —— 重签包那个文件会被删掉。
        // 与台账 `sourceURL`（「提取下载链接」的取值）无任何关系 —— 两条严格互斥。
        // 早期它是按「台账有 sourceURL」条件隐藏的，那个门控随取值来源一起作废了；
        // 两处都取不到时由 `copyLink()` 自己提示「无商店链接」。
        rows.append(RowSpec(icon: "link", tint: .teal, title: "复制商店链接") {
            copyLink()
        })
        rows.append(RowSpec(icon: "square.and.arrow.up", tint: .indigo, title: "分享 IPA") {
            shareIPA()
        })
        return rows
    }

    /// 其它操作：提取下载链接 + 删除（删除保持红色，二次确认）
    private var otherRows: [RowSpec] {
        [
            extractLinkRow,
            RowSpec(icon: "trash", tint: .red, title: "删除", titleTint: .red) {
                showDeleteConfirm = true
            }
        ]
    }

    /// 「提取下载链接」行。取值是**台账里的 IPA 包原链接**（`sourceLink`，下载中则由任务直链兜底）：
    /// 纯读本地数据，不读包、不碰任何服务 —— 与「在线安装」没有任何竞争关系，
    /// 所以**恒可点、永不置灰、也不显示任何状态字**。
    /// （v0.3.387 删掉了旧的「OTA 进行中 → 灰掉并标『安装中』」：那是本机服务时代的残留语义，
    /// 用户明确否定 —— 下载/安装状态与「提取下载链接」无关。）
    private var extractLinkRow: RowSpec {
        return RowSpec(icon: "antenna.radiowaves.left.and.right", tint: .teal, title: "提取下载链接") {
            extractDownloadLink()
        }
    }

    private var openRow: RowSpec {
        let icon = "arrow.up.forward.app.fill"
        switch openState {
        case .checking:
            return RowSpec(icon: icon, tint: .orange, title: "打开",
                           trailing: .progress, disabled: true) {}
        case .installed:
            return RowSpec(icon: icon, tint: .orange, title: "打开") {
                openApp()
            }
        case .missing:
            return RowSpec(icon: icon, tint: .orange, title: "打开",
                           trailing: .text("未安装"), disabled: true) {}
        }
    }

    private func cardSection(_ title: String, rows: [RowSpec]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 58) }
                    rowView(rows[index])
                }
            }
            .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func rowView(_ spec: RowSpec) -> some View {
        Button(action: spec.action) {
            HStack(spacing: 12) {
                AppRowIcon(systemName: spec.icon, tint: spec.tint, symbolSize: 16, frameSize: 32)
                Text(spec.title)
                    .font(.body)
                    .foregroundStyle(spec.disabled ? Color.secondary : spec.titleTint)
                    .multilineTextAlignment(.leading)
                    // 硬要求：任何一行都不许出现省略号
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailingView(spec.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(spec.disabled)
    }

    @ViewBuilder
    private func trailingView(_ trailing: RowTrailing) -> some View {
        switch trailing {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        case .progress:
            ProgressView().controlSize(.small)
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("取消")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 贴合内容高度：固定行高 × 行数 + 头图 + 三个分组标题 + 取消行 + 内边距
    ///
    /// v0.3.394：「下载中」不再裁行，所以**只有一种高度**（原来那个 pending 分支已删）。
    private var sheetHeight: CGFloat {
        let actionCount = 3                                     // 打开 / 复制商店链接 / 分享（后两条恒显示）
        let rows = 2 + actionCount + 2                          // 安装 2 行 + 其它操作 2 行
        let sections: CGFloat = 3
        let rowsHeight = CGFloat(rows) * 58 + CGFloat(rows - 3) * 1  // 行高 + 各分组内的分隔线
        return 16 + 52 + 14
            + sections * 23 + rowsHeight + (sections - 1) * 14
            + 14 + 44 + 26
    }

    // MARK: - 动作实现

    /// 在线安装：IPA 由本机服务器发（`http://127.0.0.1:<port>/package.ipa`），
    /// 清单托管到 HTTPS 后交给系统装。优先用本地已下载的包，缺文件才退回远端直链。
    private func onlineInstall() {
        let local = URL(fileURLWithPath: IPADownloadLibrary.shared.path(for: item))
        let hasLocal = FileManager.default.fileExists(atPath: local.path)
        let url = hasLocal ? local : sourceLink.flatMap { URL(string: $0) }
        OnlineInstallService.install(ipaURL: url,
                                     bundleId: item.bundleId,
                                     alternatePackageURL: hasLocal ? sourceLink : nil) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    ToastCenter.shared.show("正在安装")
                    dismiss()
                case .failure(let error):
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 复制商店链接：复制这个 App 在 **App Store 上的商店来源链接**。
    ///
    /// 取值：包内 `Payload/<App>.app/iTunesMetadata.plist` 的 **`itemId`**（商店商品号），
    /// 拼成 `https://apps.apple.com/<当前商店区>/app/id<itemId>`。
    ///
    /// **纯读本地文件：零网络、零服务**（不启动 `IPALocalHTTPServer`）。
    /// 与台账 `sourceURL` **无关** —— 那是「提取下载链接」的取值，两行严格互斥、不互相回落。
    /// 自签 / 第三方重签包一般没有 `iTunesMetadata` → 提示「无商店链接」。
    private func copyLink() {
        // ★ v0.3.391（用户要求）：「商店链接」= App Store 的跳转链接
        // `https://apps.apple.com/app/id<itemId>`，而 **itemId 在下载时就在手上**
        // （`AppStoreItem.id` 就是 `trackId`，见 `IPADownloadCenter.startWithAppleID`）
        // → 所以这里**台账优先**，不需要去读包。
        //
        // 读包内 `iTunesMetadata.itemId` 只作**兜底**：重签工具会把那个文件删掉
        // （本机 `AssppPro-4.2.5.ipa` / `NBPro_v3.6.2.ipa` 两个包实测都不含该条目），对重签包必然失败。
        if let storeId = item.storeItemId, !storeId.isEmpty {
            let link = Self.storeLink(itemId: storeId)
            UIPasteboard.general.string = link
            LoginLogger.shared.log("[下载面板] 复制商店链接（来自台账商品号 \(storeId)）"
                                   + " → \(Self.masked(link))", category: .appStore)
            ToastCenter.shared.show("已复制商店链接")
            return
        }
        let path = IPADownloadLibrary.shared.path(for: item)
        guard FileManager.default.fileExists(atPath: path) else {
            // v0.3.394：下载中还没有文件，「已不存在」是错的提示
            ToastCenter.shared.show(isPendingDownload ? "安装包尚未下载完成" : "安装包已不存在")
            return
        }
        // v0.3.391：分步读 + 分步记日志 —— 一次点击就能区分「包里压根没这个条目」
        // 与「有条目但 zip 解析失败」与「有文件但没 itemId」这三种情况。
        // （旧写法把它们并成一个 guard，日志只有一句「无 iTunesMetadata.itemId」，无法定位。）
        let metaData = IPAPackageInspector.extractiTunesMetadata(ipaPath: path)
        LoginLogger.shared.log("[下载面板] iTunesMetadata 读取："
                               + (metaData.map { "\($0.count) 字节" } ?? "取不到（包内无此条目，或 zip 解析失败）"),
                               category: .appStore)
        guard let data = metaData,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let meta = plist as? [String: Any] else {
            ToastCenter.shared.show("无商店链接")
            return
        }
        guard let itemId = Self.itemIdString(meta["itemId"]) else {
            LoginLogger.shared.log("[下载面板] iTunesMetadata 里没有 itemId；实际键=["
                                   + meta.keys.sorted().joined(separator: ", ") + "]", category: .appStore)
            ToastCenter.shared.show("无商店链接")
            return
        }
        if let bid = meta["softwareVersionBundleId"] as? String,
           let expect = item.bundleId, !expect.isEmpty, bid != expect {
            // 只记日志、不阻断：商品号仍可用，归属对不上属于诊断信息
            LoginLogger.shared.log("[下载面板] 包内 bundleId \(bid) 与台账 \(expect) 不一致", category: .appStore)
        }
        let link = Self.storeLink(itemId: itemId)
        UIPasteboard.general.string = link
        LoginLogger.shared.log("[下载面板] 复制商店链接，来自包内 iTunesMetadata（itemId \(itemId)）"
                               + " → \(Self.masked(link))", category: .appStore)
        ToastCenter.shared.show("已复制商店链接")
    }

    private func shareIPA() {
        let url = URL(fileURLWithPath: IPADownloadLibrary.shared.path(for: item))
        guard FileManager.default.fileExists(atPath: url.path) else {
            // v0.3.394：下载中还没有文件，「已不存在」是错的提示
            ToastCenter.shared.show(isPendingDownload ? "安装包尚未下载完成" : "安装包已不存在")
            return
        }
        shareTarget = ShareTarget(url: url)
    }

    /// 提取下载链接：复制这个 IPA **包本身的下载原链接**（当初是从哪个 URL 下下来的）。
    ///
    /// 取值：台账 `IPADownloadItem.sourceURL` —— **v0.3.387 起在下载时（文件名/直链确定的那一刻）
    /// 就写进台账并落盘**（`IPADownloadCenter` 调 `IPADownloadLibrary.updateSourceURL`），
    /// 不再靠界面 reload 事后回填。下载中的任务由列表把 `Job.remoteURL` 带进 `item.sourceURL`。
    ///
    /// **纯读台账：零网络、零服务、不读包** —— 与包内 `iTunesMetadata` 无关
    /// （那是「复制商店链接」的取值，两行严格互斥、不互相回落）。
    /// 与下载/安装状态**完全无关**：任何阶段都恒可点。没有直链 → 提示「无下载链接」。
    private func extractDownloadLink() {
        guard let link = sourceLink else {
            LoginLogger.shared.log("[下载面板] 台账无 sourceURL，给不出 IPA 原链接", category: .appStore)
            // v0.3.390：文案改准。AppleID 通道的地址是 Apple 按会话动态签发、必须带授权头才有效，
            // **单独一个 URL 没有意义** → 这类包本来就给不出「可用的下载直链」，不是我们没查到。
            ToastCenter.shared.show("该来源无公开直链")
            return
        }
        UIPasteboard.general.string = link
        LoginLogger.shared.log("[下载面板] 提取下载链接，来自台账 sourceURL → \(Self.masked(link))",
                               category: .appStore)
        ToastCenter.shared.show("链接已复制")
    }

    // MARK: - 包内元数据取值

    /// `itemId` 在 plist 里既可能是数字也可能是字符串，统一成字符串
    private static func itemIdString(_ raw: Any?) -> String? {
        let text: String?
        if let n = raw as? NSNumber { text = n.stringValue }
        else if let s = raw as? String { text = s }
        else { text = nil }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// 商品号 → 商店链接。区用当前商店区；`countryCode` 取不到具体区时才不带区
    private static func storeLink(itemId: String) -> String {
        let cc = AppStoreService.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cc.isEmpty ? "https://apps.apple.com/app/id\(itemId)"
                          : "https://apps.apple.com/\(cc)/app/id\(itemId)"
    }

    /// 日志脱敏：只留 host + 路径前 16 个字符，别把整条链接写进日志
    private static func masked(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else {
            return String(link.prefix(24)) + "…"
        }
        return "\(host)\(url.path.prefix(16))…"
    }

    /// 打开：设备上装了才给点 —— 复用 `JITEnableService.launchApp`
    private func openApp() {
        guard let bid = item.bundleId, !bid.isEmpty else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.launchApp(bundleID: bid)
                }.value
                await MainActor.run {
                    dismiss()
                    ToastCenter.shared.show("已打开")
                }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.show("打开失败")
                }
            }
        }
    }

    /// 判定「打开」是否可用：设备实况优先，查不到再退回本地安装记录
    private func resolveOpenState() async {
        guard let bid = item.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else {
            await MainActor.run { openState = .missing }
            return
        }
        let found: Bool? = await Task.detached(priority: .userInitiated) { () -> Bool? in
            do {
                let apps = try AppDiscovery().fetchInstalledApps()
                return apps.contains { $0.bundleIdentifier == bid }
            } catch {
                // 查不到（未配对 / 隧道不可用）→ 用本地安装记录兜底
                return nil
            }
        }.value
        await MainActor.run {
            if let found {
                openState = found ? .installed : .missing
            } else {
                openState = item.lastInstalledAt != nil ? .installed : .missing
            }
        }
    }
}
