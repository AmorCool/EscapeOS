import SwiftUI
import UniformTypeIdentifiers

/// IPCC 安装：导入运营商配置文件（.ipcc），经 AFC 隧道上传到
/// /var/mobile/Media/PublicStaging，再调 CoreTelephony 私有 API
/// 交给 CommCenter 安装（爱思助手 / iTunes / Finder 同一条系统管线）。
struct IPCCInstallView: View {
    @State private var showImporter = false
    @State private var parsed: IPCCInstallService.ParsedIPCC?
    @State private var parsedURL: URL?
    @State private var installing = false
    @State private var records: [IPCCInstallService.InstallRecord] = []
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var showRespringHint = false
    /// v0.2.130：查看安装日志详情的记录。
    @State private var detailRecord: IPCCInstallService.InstallRecord?

    private let service = IPCCInstallService.shared

    var body: some View {
        List {
            Section {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
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
                                Text("正在上传并安装…")
                            }
                        } else {
                            Label("更新 IPCC（官方通道）", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(installing)
                }
            } header: {
                Text("安装运营商包")
            } footer: {
                Text("与爱思助手 / iTunes「更新 IPCC」同一套系统管线：文件上传到 PublicStaging 后交给 CommCenter 安装。成功受理后建议重启设备生效。")
            }

            Section {
                if records.isEmpty {
                    Text("暂无安装记录")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(records) { record in
                        HStack {
                            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(record.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(record.bundleName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if !record.detail.isEmpty {
                                    Text(record.detail)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Button {
                                detailRecord = record
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundColor(.blue)
                            }
                            .accessibilityLabel("查看日志")
                        }
                    }
                }
            } header: {
                Text("最近安装记录")
            } footer: {
                Text("安装后的实际 bundle 由 CommCenter 写入系统区，本机无法直接查看 / 卸载（由系统统一管理）。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("IPCC 安装")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reloadRecords()
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
        .alert("已提交安装", isPresented: $showRespringHint) {
            Button("好的") {}
        } message: {
            Text("已通过 installation_proxy（PackageType=CarrierBundle）交给系统安装，与爱思助手「更新 IPCC」同一条通道。建议重启设备（或「更多 → 设备控制 → 重启 SpringBoard」）后查看生效情况。")
        }
        .sheet(item: $detailRecord) { record in
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(record.success ? .green : .red)
                            Text(record.success ? "安装成功" : "安装失败")
                                .font(.headline)
                        }
                        Text(record.fileName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Divider()
                        if record.steps.isEmpty {
                            Text(record.detail.isEmpty ? "（无详细日志）" : record.detail)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(Array(record.steps.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("安装日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { detailRecord = nil }
                    }
                }
            }
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
            reloadRecords()
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
                    toast = "已交给 CommCenter：\(path)"
                    showRespringHint = true
                    reloadRecords()
                }
            } catch {
                DispatchQueue.main.async {
                    installing = false
                    errorMessage = "安装失败：\(error.localizedDescription)"
                    reloadRecords()
                }
            }
        }
    }

    private func reloadRecords() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = service.savedRecords()
            DispatchQueue.main.async {
                records = list
            }
        }
    }
}
