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

                cardSection("危险", rows: dangerRows)

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
            RowSpec(icon: "icloud.and.arrow.down", tint: .green, title: "在线安装",
                    trailing: OnlineInstallService.isImplemented ? RowTrailing.none : .text("未接入")) {
                onlineInstall()
            }
        ]
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

    /// 危险：删除（红色，二次确认）
    private var dangerRows: [RowSpec] {
        [
            RowSpec(icon: "trash", tint: .red, title: "删除", titleTint: .red) {
                showDeleteConfirm = true
            }
        ]
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
        let rows = 2 + actionCount + 1                          // 安装 2 行 + 危险 1 行
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
