import SwiftUI
import UIKit

/// v0.3.378：已下载 IPA 的操作面板 —— 「下载管理」点任意一行弹出。
///
/// 动作对齐 NB 全能助手：覆盖安装 / 在线安装 / 打开 / 复制下载链接 / 分享 / 删除 / 取消。
/// 视觉沿用虚拟定位页的液态玻璃卡片（`locusGlass`）+ `AppRowIcon` 图标基调。
///
/// **全部复用既有实现，不另起炉灶**：
/// · 覆盖安装 → 下载中心 `installLocal`（→ `AppStoreInstallService.installLocalIPA`）
/// · 打开     → `JITEnableService.launchApp(bundleID:)`
/// · 分享     → `ShareSheet`（`UIActivityViewController` 包装）
/// · 提取下载链接 → `IPALocalHTTPServer.shared.start(fileURL:purpose:.share)`（本机 HTTP 服务，取 `Serving.packageURL`）
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

    /// 台账里真实存在的来源直链（没有就不显示「复制下载链接」）
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
    private var installRows: [RowSpec] {
        [
            RowSpec(icon: "arrow.down.app.fill", tint: .blue, title: "覆盖安装") {
                onOverwriteInstall()
                dismiss()
            },
            onlineInstallRow
        ]
    }

    /// 「在线安装」行。置灰规则：本机服务器当前被「提取下载链接」占用（`Purpose.share`）
    /// 时不可点 —— 单例 server 一次只服务一份文件，再 `start()` 会先 `stop()` 掉那个分享会话。
    private var onlineInstallRow: RowSpec {
        if !OnlineInstallService.isImplemented {
            return RowSpec(icon: "icloud.and.arrow.down", tint: .green, title: "在线安装",
                           trailing: .text("未接入")) {
                onlineInstall()
            }
        }
        let blockedByShare = IPALocalHTTPServer.shared.currentPurpose == .share
        return RowSpec(icon: "icloud.and.arrow.down", tint: .green, title: "在线安装",
                       trailing: blockedByShare ? .text("分享中") : RowTrailing.none,
                       disabled: blockedByShare) {
            onlineInstall()
        }
    }

    private var actionRows: [RowSpec] {
        var rows: [RowSpec] = [openRow]
        if sourceLink != nil {
            rows.append(RowSpec(icon: "link", tint: .teal, title: "复制下载链接") {
                copyLink()
            })
        }
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

    /// 「提取下载链接」行。置灰规则：本机服务器当前被「在线安装」占用（`Purpose.ota`）
    /// 时不可点 —— 一 `start()` 就会 `stop()` 掉 OTA 会话，把正在进行的系统安装打断。
    /// 生成一个**本机下载链接**发出去（不依赖有没有来源直链）：
    /// 复用 `IPALocalHTTPServer` 只服务这一个文件的只读路由 `/package.ipa`。
    private var extractLinkRow: RowSpec {
        let blockedByOTA = IPALocalHTTPServer.shared.currentPurpose == .ota
        return RowSpec(icon: "antenna.radiowaves.left.and.right", tint: .teal, title: "提取下载链接",
                       trailing: blockedByOTA ? .text("安装中") : RowTrailing.none,
                       disabled: blockedByOTA) {
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
    private var sheetHeight: CGFloat {
        let actionCount = 1 + (sourceLink == nil ? 0 : 1) + 1   // 打开 / [复制下载链接] / 分享
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

    private func copyLink() {
        guard let link = sourceLink else { return }
        UIPasteboard.general.string = link
        ToastCenter.shared.show("已复制下载链接")
    }

    private func shareIPA() {
        let url = URL(fileURLWithPath: IPADownloadLibrary.shared.path(for: item))
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastCenter.shared.show("安装包已不存在")
            return
        }
        shareTarget = ShareTarget(url: url)
    }

    /// 提取下载链接：把本地包用**本机 HTTP 服务**发出去，给这个包生成一个下载地址。
    /// 地址由服务端给（`Serving.packageURL`）：优先 `http://<设备局域网IP>:<port>/package.ipa`，
    /// 取不到局域网 IP 才回落 `127.0.0.1`（见 `IPALocalHTTPServer.start`）。**不依赖来源直链。**
    private func extractDownloadLink() {
        let url = URL(fileURLWithPath: IPADownloadLibrary.shared.path(for: item))
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastCenter.shared.show("安装包已不存在")
            return
        }
        do {
            // 与「在线安装」共用同一个 shared 实例；start() 内部会先 stop() 掉上一份会话
            let serving = try IPALocalHTTPServer.shared.start(fileURL: url, purpose: .share)
            UIPasteboard.general.string = serving.packageURL
            LoginLogger.shared.log("[下载面板] 本机分享服务已启动 \(serving.packageURL)", category: .appStore)
            ToastCenter.shared.show("链接已复制")
            // 不常驻：10 分钟后自动关（别让服务器一直开着）
            IPALocalHTTPServer.shared.stop(after: 10 * 60)
        } catch {
            LoginLogger.shared.log("[下载面板] 本机分享服务启动失败：\(error.localizedDescription)",
                                   category: .appStore)
            ToastCenter.shared.show("无法生成链接")
        }
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
