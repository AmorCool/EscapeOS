import SwiftUI
import UniformTypeIdentifiers

/// 发送描述文件：导入 .mobileconfig（如屏蔽 iOS 更新、Wi-Fi、VPN 等配置），
/// 一键发送到本机设置安装。
///
/// 原理（与爱思助手同款）：App 内起 127.0.0.1 本地 HTTP 服务（复用
/// `ProfileHTTPServer`，DomainBlocker 同款），把描述文件以
/// `application/x-apple-aspen-config` 暴露给 Safari，Safari 交给系统
/// 描述文件摄取流程 → 用户到「设置 → 通用 → VPN 与设备管理」安装。
struct ProfileInstallView: View {
    @State private var profiles: [String] = []
    @State private var showImporter = false
    @State private var busy = false
    @State private var toast: String?
    @State private var confirmDelete: String?

    /// 描述文件保存目录（Documents/Profiles，文件 App 可见）。
    private var profilesDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("导入描述文件", systemImage: "doc.badge.plus")
                }
                .foregroundColor(.blue)
            } header: {
                Text("描述文件管理")
            } footer: {
                Text("支持导入 .mobileconfig 。导入后点「发送到本机」→ 系统提示已下载 → 到「设置 → 通用 → VPN 与设备管理」安装。")
            }

            Section {
                if profiles.isEmpty {
                    Text("暂无描述文件")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(profiles, id: \.self) { name in
                        HStack(spacing: 12) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(profileSummary(named: name))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                sendToSettings(name: name)
                            } label: {
                                if busy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("发送到本机", systemImage: "paperplane.fill")
                                        .font(.caption)
                                }
                            }
                            .disabled(busy)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                confirmDelete = name
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("已导入")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("发送描述文件")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            reload()
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "mobileconfig") ?? .item]) { urls in
            guard let url = urls.first else { return }
            importProfile(url: url)
        }
        .alert("删除 \(confirmDelete ?? "")？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let name = confirmDelete {
                    deleteProfile(named: name)
                    reload()
                }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear {
            reload()
        }
    }

    // MARK: - 操作

    private func reload() {
        let fm = FileManager.default
        profiles = ((try? fm.contentsOfDirectory(atPath: profilesDirectory)) ?? [])
            .filter { $0.hasSuffix(".mobileconfig") }
            .sorted()
    }

    private func importProfile(url: URL) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else { throw makeError("文件为空") }
                let name = url.lastPathComponent
                let target = URL(fileURLWithPath: profilesDirectory).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try data.write(to: target)
                DispatchQueue.main.async {
                    busy = false
                    toast = "已导入：\(name)"
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    toast = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteProfile(named name: String) {
        let path = URL(fileURLWithPath: profilesDirectory).appendingPathComponent(name).path
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 启动本地 HTTP 服务 + Safari 打开（与 DomainBlocker 同款）。
    private func sendToSettings(name: String) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = (profilesDirectory as NSString).appendingPathComponent(name)
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let port = try ProfileHTTPServer.shared.start(payload: data, filename: name)
                guard let openURL = URL(string: "http://127.0.0.1:\(port)/") else {
                    throw ProfileServerError.bind(errno: 0)
                }
                DispatchQueue.main.async {
                    var bgTask = UIBackgroundTaskIdentifier.invalid
                    bgTask = UIApplication.shared.beginBackgroundTask(withName: "ProfileInstall") {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }
                    UIApplication.shared.open(openURL, options: [:]) { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                            ProfileHTTPServer.shared.stop()
                            if bgTask != .invalid {
                                UIApplication.shared.endBackgroundTask(bgTask)
                                bgTask = .invalid
                            }
                        }
                    }
                    busy = false
                    toast = "已打开 Safari：到「设置 → 通用 → VPN 与设备管理」安装"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    toast = "发送失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 读取描述文件 PayloadDisplayName（有则显示，无则显示文件大小）。
    private func profileSummary(named name: String) -> String {
        let path = (profilesDirectory as NSString).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let displayName = plist["PayloadDisplayName"] as? String else {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return displayName
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "Profile", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
