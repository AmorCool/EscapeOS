import SwiftUI

/// v0.3.234：配对文件导入（本机）——重置/更换配对文件后从这里重新导入
/// `pairingFile.plist` 到 App Documents（RSD 隧道凭证，全服务共用）。
/// 注意区分：「管理配对文件」（PairingInstallView）是把配对写入其它侧载工具。
struct PairingImportView: View {
    @State private var hasFile = false
    @State private var fileDate: Date?
    @State private var fileSize: Int64 = 0
    @State private var toast: String?
    @State private var confirmReset = false

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(hasFile ? "配对文件已导入" : "未检测到配对文件",
                          systemImage: hasFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(hasFile ? .green : .orange)
                    if hasFile {
                        if let d = fileDate {
                            Text("导入时间：\(d.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("大小：\(fileSize) 字节").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("所有依赖 RSD 隧道的功能（应用管理 / 空间回收 / 设备信息等）均不可用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } header: {
                Text("当前状态")
            }

            Section {
                Button {
                    importFilePicker()
                } label: {
                    Label(hasFile ? "重新导入配对文件" : "导入配对文件", systemImage: "square.and.arrow.down")
                }
                if hasFile {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("删除配对文件（重置）", systemImage: "trash")
                    }
                }
            } footer: {
                Text("从电脑侧导出的 pairingFile.plist 导入。导入后即可使用应用管理、空间回收等全部隧道功能。")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("与「管理配对文件」的区别").font(.caption.weight(.semibold))
                    Text("· 本页：导入配对文件到 EscapeSpace 自身（隧道凭证）\n· 管理配对文件：把已有配对写入其它侧载工具，复用同一身份")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配对文件导入")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(Color(.systemBackground)))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .onAppear { refreshStatus() }
        .confirmationDialog("删除配对文件？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("删除（重置）", role: .destructive) { resetPairing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后所有隧道功能将不可用，需重新导入。")
        }
    }

    private func refreshStatus() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: pairingPath) {
            hasFile = true
            fileDate = attrs[.modificationDate] as? Date
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            hasFile = false
            fileDate = nil
            fileSize = 0
        }
    }

    private func importFilePicker() {
        SharedDocumentPicker.present(allowedTypes: [.data], onPicked: { urls in
            importPairing(url: urls.first)
        }, onCancelled: {})
    }

    private func importPairing(url: URL?) {
        guard let url else { return }
        guard let data = try? Data(contentsOf: url) else {
            showToast("读取文件失败")
            return
        }
        // 基础校验：plist（xml 头或 bplist 魔数）
        let isPlist = data.range(of: Data("<?xml".utf8)) != nil
            || data.range(of: Data("bplist00".utf8)) != nil
        guard isPlist else {
            showToast("不是有效的 plist 配对文件")
            return
        }
        let dest = URL(fileURLWithPath: pairingPath)
        do {
            try data.write(to: dest, options: .atomic)
            refreshStatus()
            showToast("已导入：\(url.lastPathComponent)")
        } catch {
            showToast("写入失败：\(error.localizedDescription)")
        }
    }

    private func resetPairing() {
        try? FileManager.default.removeItem(atPath: pairingPath)
        refreshStatus()
        showToast("已删除配对文件")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }
}
