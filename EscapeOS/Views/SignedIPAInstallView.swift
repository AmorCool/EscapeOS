import SwiftUI
import UniformTypeIdentifiers

/// IPA 安装（已签名包在线安装 / 覆盖升级降级）—— 爱思助手同款通道。
///
/// 与「IPA 侧载」的区别：侧载走 isideload 签名流程（Apple ID 登录签名）；
/// 本页接收**已经签好名**的 .ipa（App Store 下载包、爱思/AltStore 签过的
/// 包等），经 RSD 隧道直接交给 installation_proxy 安装，无需再次签名：
/// - 在线安装：`Install` 命令（新装 / 覆盖已存在同 bundle id 应用）
/// - 覆盖升级 / 降级安装：`Upgrade` 命令（installd 允许降级，
///   App Store 客户端禁止但 installation_proxy 不拦）
struct SignedIPAInstallView: View {
    @State private var showImporter = false
    @State private var importedURL: URL?
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var toast: String?

    private let service = IPAInstallService.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "app.badge.checkmark")
                            .font(.title3)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已签名 IPA 安装")
                                .font(.subheadline.weight(.semibold))
                            Text("无视版本，经隧道直接安装")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    Button {
                        self.showImporter = true
                    } label: {
                        Label("选择已签名 IPA 文件", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(busy)
                }
                .padding(.vertical, 4)
            } header: {
                Text("选择 IPA")
            } footer: {
                Text("支持 App Store 下载包、AppleID 等已签名 .ipa.选择后可按需执行安装.")
            }

            if busy {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text(String(format: "安装中 %.0f%%…", progress * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        .foregroundColor(.red)
                } header: {
                    Label("错误", systemImage: "exclamationmark.triangle")
                }
            }

            if !self.busy && self.importedURL != nil {
                Section {
                    Button {
                        self.install(mode: .install)
                    } label: {
                        Label("在线安装", systemImage: "arrow.down.circle.fill")
                    }
                    .foregroundColor(.blue)

                    Button {
                        self.install(mode: .upgrade)
                    } label: {
                        Label("覆盖升级 / 降级安装", systemImage: "arrow.up.arrow.down.circle")
                    }
                    .foregroundColor(.blue)
                } header: {
                    Label("执行安装", systemImage: "hammer")
                } footer: {
                    Text("在线安装：新装或覆盖同 bundle id 应用；覆盖升级/降级：对已安装应用升级或回退版本.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("IPA 安装")
        .navigationBarTitleDisplayMode(.inline)
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
            guard let url = urls.first else { return }
            self.importedURL = url
            self.errorMessage = nil
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
    }

    private enum InstallMode {
        case install
        case upgrade
    }

    private func install(mode: InstallMode) {
        guard let importedURL = self.importedURL else { return }
        let localPath = importedURL.path
        self.busy = true
        self.progress = 0
        self.errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch mode {
                case .install:
                    try self.service.installSignedIPA(localPath) { value in
                        DispatchQueue.main.async { self.progress = value }
                    }
                case .upgrade:
                    try self.service.upgradeSignedIPA(localPath) { value in
                        DispatchQueue.main.async { self.progress = value }
                    }
                }
                DispatchQueue.main.async {
                    self.busy = false
                    self.progress = 1
                    self.toast = mode == .install ? "在线安装成功" : "覆盖升级/降级安装成功"
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.errorMessage = "安装失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
