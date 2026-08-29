import SwiftUI
import UniformTypeIdentifiers

/// IPCC 安装：导入运营商配置文件（.ipcc），解包写入
/// /var/mobile/Library/Carrier Bundles/Overrides，重启后生效。
struct IPCCInstallView: View {
    @State private var showImporter = false
    @State private var parsed: IPCCInstallService.ParsedIPCC?
    @State private var parsedURL: URL?
    @State private var installing = false
    @State private var installed: [IPCCInstallService.InstalledBundle] = []
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var confirmUninstall: IPCCInstallService.InstalledBundle?
    @State private var showRespringHint = false

    private let service = IPCCInstallService.shared

    var body: some View {
        List {
            Section {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
                if let parsed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(parsed.bundleName)
                            .font(.subheadline.weight(.semibold))
                        Text("标识：\(parsed.identifier.isEmpty ? "未知" : parsed.identifier)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("版本：\(parsed.version.isEmpty ? "未知" : parsed.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    showImporter = true
                } label: {
                    Label(parsed == nil ? "选择 IPCC 文件" : "重新选择", systemImage: "doc.badge.plus")
                }
                if parsed != nil {
                    Button {
                        install()
                    } label: {
                        if installing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在安装…")
                            }
                        } else {
                            Label("安装到 Overrides", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(installing)
                }
            } header: {
                Text("安装运营商包")
            } footer: {
                Text("IPCC 是运营商配置文件（zip 格式）。安装后需要重启设备或 SpringBoard 才能生效。")
            }

            Section {
                if installed.isEmpty {
                    Text("尚未安装自定义运营商包")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(installed) { bundle in
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bundle.name)
                                    .font(.subheadline)
                                Text(bundle.identifier.isEmpty ? "标识未知" : bundle.identifier)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !bundle.version.isEmpty {
                                    Text("版本 \(bundle.version)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                confirmUninstall = bundle
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("已安装")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("IPCC 安装")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reloadInstalled()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新")
            }
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "ipcc") ?? .item]) { urls in
            guard let url = urls.first else { return }
            parse(url: url)
        }
        .confirmationDialog(
            "删除 \(confirmUninstall?.name ?? "")？",
            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { doUninstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后需要重启设备或 SpringBoard 才能恢复系统默认运营商配置。")
        }
        .alert("安装完成", isPresented: $showRespringHint) {
            Button("好的") {}
        } message: {
            Text("运营商包已写入 Overrides。建议重启设备（或使用「更多 → 设备控制」重启 SpringBoard）后生效。")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear {
            reloadInstalled()
        }
    }

    // MARK: - 操作

    private func parse(url: URL) {
        errorMessage = nil
        parsed = nil
        parsedURL = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try service.parse(ipccURL: url)
                DispatchQueue.main.async {
                    parsed = info
                    parsedURL = url
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "解析失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func install() {
        guard let parsedURL else { return }
        installing = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try service.install(ipccURL: parsedURL)
                DispatchQueue.main.async {
                    installing = false
                    parsed = nil
                    self.parsedURL = nil
                    toast = "已安装到 \(path)"
                    showRespringHint = true
                    reloadInstalled()
                }
            } catch {
                DispatchQueue.main.async {
                    installing = false
                    errorMessage = "安装失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func doUninstall() {
        guard let target = confirmUninstall else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.uninstall(target)
                DispatchQueue.main.async {
                    confirmUninstall = nil
                    toast = "已删除 \(target.name)"
                    reloadInstalled()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "删除失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func reloadInstalled() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = service.listInstalled()
            DispatchQueue.main.async {
                installed = list
            }
        }
    }
}
