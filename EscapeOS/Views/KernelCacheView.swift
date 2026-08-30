import SwiftUI
import UIKit

/// 下载 KernelCache：从 Apple CDN 的 IPSW 里用 Range 请求只拉 kernelcache
/// 文件（无需下载数 GB 整包），零权限、零漏洞。
///
/// 原理（详见 KernelCacheService）：
/// 自动识别当前机型（hw.machine）+ 系统版本（UIDevice）→ ipsw.me 查该机型
/// 全部固件 → 默认选中当前系统版本（一键提取），也可手动选择其他机型/版本
/// → 解析 ZIP64 目录定位 kernelcache.release 条目 → 分块 Range 下载
/// （~20MB）→ raw deflate 解压 → 校验 0x30 0x84 magic → 保存。
struct KernelCacheView: View {
    @State private var deviceIdentifier = ""
    @State private var systemVersion = ""
    @State private var firmwares: [KernelCacheService.Firmware] = []
    @State private var selectedFirmware: KernelCacheService.Firmware?
    @State private var isQuerying = false
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var savedFiles: [String] = []
    @State private var shareURL: ShareURL?
    @State private var confirmDelete: String?
    /// 手动选择机型弹窗。
    @State private var showIdentifierPicker = false
    @State private var identifierInput = ""

    private let service = KernelCacheService.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(deviceIdentifier) · iOS \(systemVersion)")
                                .font(.subheadline.weight(.semibold))
                            if let selectedFirmware {
                                Text("目标：\(selectedFirmware.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if isQuerying {
                                Text("正在查询固件列表…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Text("从 Apple CDN 的 IPSW 中按偏移只下载 kernelcache 文件（约 20MB，无需下载整包数 GB），零权限、零漏洞，与越狱工具从设备读取的 kernelcache 是同一份文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        startDownload()
                    } label: {
                        if isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("下载中…")
                            }
                        } else {
                            Label("一键下载当前系统 KernelCache", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(isRunning || selectedFirmware == nil)
                }
                .padding(.vertical, 4)
            } header: {
                Text("内核缓存下载")
            } footer: {
                Text("默认按当前机型与系统版本自动匹配；也可在下方手动切换机型/版本。")
            }

            // 手动选择区
            Section {
                // 机型选择
                HStack {
                    Text("机型")
                    Spacer()
                    Button {
                        identifierInput = deviceIdentifier
                        showIdentifierPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(deviceIdentifier.isEmpty ? "请选择" : deviceIdentifier)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // 版本选择
                if !firmwares.isEmpty {
                    HStack {
                        Text("系统版本")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { selectedFirmware?.buildid ?? "" },
                            set: { newID in
                                selectedFirmware = firmwares.first { $0.buildid == newID }
                            }
                        )) {
                            ForEach(firmwares) { fw in
                                Text(fw.displayName).tag(fw.buildid)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                    }
                } else if isQuerying {
                    HStack {
                        Text("系统版本")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("手动选择")
            } footer: {
                Text("默认已自动识别当前机型与系统版本；如需下载其他机型 / 其他版本的 kernelcache，可在此手动切换。")
            }

            if isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("进度", systemImage: "timer")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } header: {
                    Label("错误", systemImage: "exclamationmark.triangle")
                }
            }

            if let shareURL {
                Section {
                    Button {
                        shareFile(shareURL.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("分享下载的文件")
                                    .font(.subheadline.weight(.semibold))
                                Text(shareURL.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Label("最新下载", systemImage: "checkmark.circle")
                }
            }

            if !savedFiles.isEmpty {
                Section {
                    ForEach(savedFiles, id: \.self) { name in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.zipper")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(fileSizeText(named: name))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                shareFile(URL(fileURLWithPath: (KernelCacheService.saveDirectory as NSString).appendingPathComponent(name)))
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("分享 \(name)")
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                confirmDelete = name
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Label("已下载", systemImage: "folder")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载 KernelCache")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            reload()
        }
        .alert("删除 \(confirmDelete ?? "")？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let name = confirmDelete {
                    service.deleteSavedFile(named: name)
                    reload()
                }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("选择机型", isPresented: $showIdentifierPicker) {
            TextField("机型标识，如 iPhone13,1", text: $identifierInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("查询") {
                applyIdentifier(identifierInput)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入要下载 kernelcache 的机型标识（hw.machine，如 iPhone13,1 / iPhone15,2）。")
        }
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
        .onAppear {
            if deviceIdentifier.isEmpty {
                loadDeviceInfo()
            }
            reload()
        }
    }

    // MARK: - 数据

    /// 自动识别当前机型 + 系统版本，并加载固件列表、默认选中当前版本。
    private func loadDeviceInfo() {
        let identifier = service.deviceIdentifier()
        let version = service.systemVersion()
        deviceIdentifier = identifier
        systemVersion = version
        guard !identifier.isEmpty else {
            errorMessage = "无法获取设备型号"
            return
        }
        Task {
            await queryFirmwares(identifier: identifier, autoSelectVersion: version)
        }
    }

    /// 手动指定机型后重新查询固件列表。
    private func applyIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceIdentifier = trimmed
        selectedFirmware = nil
        firmwares = []
        errorMessage = nil
        Task {
            // 手动选择机型时保留自动识别的系统版本做默认匹配；
            // 若该机型无此版本则只列列表让用户手选。
            await queryFirmwares(identifier: trimmed, autoSelectVersion: systemVersion)
        }
    }

    /// 查询指定机型的全部固件；autoSelectVersion 非空时自动选中该版本。
    @MainActor
    private func queryFirmwares(identifier: String, autoSelectVersion: String?) async {
        isQuerying = true
        errorMessage = nil
        defer { isQuerying = false }
        do {
            let list = try await service.listFirmwares(identifier: identifier)
            firmwares = list
            if let autoSelectVersion,
               let matched = service.matchFirmware(in: list, version: autoSelectVersion) {
                selectedFirmware = matched
            } else {
                selectedFirmware = list.first
            }
        } catch {
            errorMessage = "查询固件信息失败：\(error.localizedDescription)"
        }
    }

    private func reload() {
        savedFiles = service.savedFiles()
        if let latest = savedFiles.last {
            shareURL = ShareURL(url: URL(fileURLWithPath: (KernelCacheService.saveDirectory as NSString).appendingPathComponent(latest)))
        } else {
            shareURL = nil
        }
    }

    private func startDownload() {
        errorMessage = nil
        isRunning = true
        progress = 0
        Task {
            await performDownload()
        }
    }

    @MainActor
    private func performDownload() async {
        guard let firmware = selectedFirmware else {
            isRunning = false
            return
        }
        do {
            status = "正在解析 IPSW 目录…"
            let path = try await service.downloadKernelCache(firmware: firmware) { value in
                progress = value
                status = String(format: "下载中 %.0f%%", value * 100)
            }
            isRunning = false
            status = "完成"
            shareURL = ShareURL(url: URL(fileURLWithPath: path))
            reload()
        } catch {
            isRunning = false
            errorMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    private func shareFile(_ url: URL) {
        shareURL = ShareURL(url: url)
    }

    private func fileSizeText(named name: String) -> String {
        let path = (KernelCacheService.saveDirectory as NSString).appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[FileAttributeKey.size] as? NSNumber else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }
}
