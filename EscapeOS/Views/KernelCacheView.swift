import SwiftUI
import UIKit

/// 下载 KernelCache：从 Apple CDN 的 IPSW 里用 Range 请求只拉 kernelcache
/// 文件（无需下载数 GB 整包），零权限、零漏洞。
///
/// 原理（详见 KernelCacheService）：当前设备型号 + 系统版本 → ipsw.me 查
/// 对应 IPSW → 解析 ZIP64 目录定位 kernelcache.release 条目 → 分块 Range
/// 下载（~20MB）→ raw deflate 解压 → 校验 0x30 0x84 magic → 保存。
struct KernelCacheView: View {
    @State private var deviceIdentifier = ""
    @State private var systemVersion = ""
    @State private var buildID = ""
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var savedFiles: [String] = []
    @State private var shareURL: ShareURL?
    @State private var confirmDelete: String?

    private let service = KernelCacheService.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(deviceIdentifier) · iOS \(systemVersion)")
                                .font(.subheadline.weight(.semibold))
                            Text(buildID.isEmpty ? "正在查询固件信息…" : "目标固件：iOS \(systemVersion) (\(buildID))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            Label("下载 KernelCache", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.accent)
                    .disabled(isRunning || deviceIdentifier.isEmpty)
                }
                .padding(.vertical, 4)
            } header: {
                Text("内核缓存下载")
            } footer: {
                Text("lara 原版依赖内核漏洞（vn_fileredirect）无法在 EscapeSpace 复现，本页改用官方 IPSW 直拉方案，结果一致。")
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
                                .foregroundStyle(AppTheme.accent)
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
                                shareFile(URL(fileURLWithPath: (service.saveDirectory as NSString).appendingPathComponent(name)))
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
            await lookupFirmware(identifier: identifier, version: version)
        }
    }

    @MainActor
    private func lookupFirmware(identifier: String, version: String) async {
        do {
            let firmware = try await service.findFirmware(identifier: identifier, version: version)
            buildID = firmware.buildid
        } catch {
            errorMessage = "查询固件信息失败：\(error.localizedDescription)"
        }
    }

    private func reload() {
        savedFiles = service.savedFiles()
        if let latest = savedFiles.last {
            shareURL = ShareURL(url: URL(fileURLWithPath: (service.saveDirectory as NSString).appendingPathComponent(latest)))
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
        do {
            let firmware = try await service.findFirmware(identifier: deviceIdentifier, version: systemVersion)
            buildID = firmware.buildid
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
        let path = (service.saveDirectory as NSString).appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }
}
