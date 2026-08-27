import SwiftUI

/// 配置导入（汉化移植自 SideInstaller 的「配对 → 安装到应用」）。
///
/// 扫描设备上已安装的支持列表应用（SideStore / LiveContainer / Feather /
/// StikDebug 等），把当前配对文件写入它们的容器，让这些应用复用同一份
/// 配对身份。链路为 LocalDevVPN 隧道 + house_arrest，不依赖本地网络权限。
struct PairingInstallView: View {
    @State private var targets: [PairingInstallService.InstalledTarget] = []
    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var installingID: String?
    @State private var isInstallingAll = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showSuccess = false

    private var isBusy: Bool { isScanning || isInstallingAll || installingID != nil }

    private var pairingFileExists: Bool {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return false }
        return size > 0
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "tray.and.arrow.down.fill", tint: .blue, symbolSize: 20, frameSize: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("配置导入")
                                .font(.headline)
                            Text("把配对文件写入已安装的侧载工具，让它们复用同一份配对身份。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    if !pairingFileExists {
                        Label("未检测到配对文件，请先在「应用」页导入", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 6)
            }

            if let error = errorMessage {
                Section {
                    InfoActionCard(
                        icon: "exclamationmark.triangle.fill",
                        iconTint: .red,
                        title: "出错了",
                        message: error
                    )
                }
            }

            if let success = successMessage {
                Section {
                    InfoActionCard(
                        icon: "checkmark.seal.fill",
                        iconTint: .green,
                        title: "完成",
                        message: success
                    )
                }
            }

            Section {
                Button {
                    scan()
                } label: {
                    HStack {
                        if isScanning {
                            ProgressView().controlSize(.small)
                            Text("正在扫描…")
                        } else {
                            Image(systemName: hasScanned ? "arrow.clockwise" : "magnifyingglass")
                            Text(hasScanned ? "重新扫描应用" : "扫描支持的应用")
                        }
                        Spacer()
                    }
                }
                .disabled(isBusy)
            } footer: {
                Text("通过 LocalDevVPN 隧道扫描设备上已安装的侧载工具。")
            }

            if hasScanned && targets.isEmpty && !isScanning {
                Section {
                    InfoActionCard(
                        icon: "questionmark.app.dashed",
                        iconTint: .blue,
                        title: "未找到支持的应用",
                        message: "请先在设备上安装 SideStore、LiveContainer、Feather 或 StikDebug 等应用，再重新扫描。"
                    )
                }
            } else if !targets.isEmpty {
                Section {
                    if targets.count > 1 {
                        Button {
                            installAll()
                        } label: {
                            HStack {
                                if isInstallingAll {
                                    ProgressView().controlSize(.small)
                                    Text("正在写入全部应用…")
                                } else {
                                    Image(systemName: "square.and.arrow.down.on.square")
                                    Text("写入全部 \(targets.count) 个应用")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isBusy)
                    }
                    ForEach(targets) { target in
                        targetRow(target)
                    }
                } header: {
                    Text("支持的应用（\(targets.count)）")
                } footer: {
                    Text("配对文件会写入各应用的 Documents 目录（SideStore 等以各自约定的文件名读取）。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配置导入")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 目标行

    private func targetRow(_ target: PairingInstallService.InstalledTarget) -> some View {
        let installing = installingID == target.id
        return HStack(spacing: 12) {
            AppRowIcon(systemName: "app.dashed", tint: .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.subheadline.weight(.semibold))
                Text(target.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                install(into: target)
            } label: {
                if installing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("写入")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.blue)
            .disabled(isBusy)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 动作

    private func scan() {
        guard !isBusy else { return }
        errorMessage = nil
        successMessage = nil
        isScanning = true
        Task {
            do {
            targets = try await Task.detached(priority: .userInitiated) {
                try PairingInstallService.shared.scanTargets()
            }.value
                hasScanned = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    private func install(into target: PairingInstallService.InstalledTarget) {
        guard !isBusy else { return }
        errorMessage = nil
        successMessage = nil
        installingID = target.id
        Task {
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try PairingInstallService.shared.installPairing(into: target)
                }.value
                successMessage = "已写入 \(target.name)（\(bytes) 字节，读回已验证）。"
            } catch {
                errorMessage = error.localizedDescription
            }
            installingID = nil
        }
    }

    private func installAll() {
        guard !isBusy, !targets.isEmpty else { return }
        errorMessage = nil
        successMessage = nil
        isInstallingAll = true
        let all = targets
        Task {
            do {
                let failures = try await Task.detached(priority: .userInitiated) {
                    try PairingInstallService.shared.installPairing(intoAll: all)
                }.value
                if failures.isEmpty {
                    successMessage = "已写入全部 \(all.count) 个应用，读回已验证。"
                } else {
                    errorMessage = "以下应用写入失败：\n" + failures.joined(separator: "\n")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isInstallingAll = false
        }
    }
}
