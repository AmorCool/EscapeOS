import SwiftUI

/// v0.3.228：MDM 管理（「更多」板块入口）——
/// 移植 mond-main MDM 绕过：5 层沙盒逃逸策略 + 描述文件备份/清空/还原.
/// 仅个人测试用途；iOS 26.5+ 侧载环境可能被沙盒策略拦截（结果如实显示）.
struct MDMManageView: View {
    @State private var escapeMethod: String?
    @State private var escapeTarget: String?
    @State private var probing = false
    @State private var fileStates: [(name: String, present: Bool)] = []
    @State private var hasBackups = false
    @State private var logs: [String] = []
    @State private var alertTitle = ""
    @State private var alertBody = ""
    @State private var showAlert = false

    var body: some View {
        List {
            // 状态卡
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("MDM 配置目录沙盒逃逸", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .font(.headline)
                    if probing {
                        HStack { ProgressView().controlSize(.small); Text("正在逐层尝试逃逸策略…") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let m = escapeMethod {
                        Text("逃逸成功：\(m)").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        Text(escapeTarget ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("未逃逸（点击下方「检测逃逸」尝试 5 层策略）")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // 描述文件状态
            if !fileStates.isEmpty {
                Section("ConfigurationProfiles 核心文件") {
                    ForEach(fileStates, id: \.name) { f in
                        HStack {
                            Image(systemName: f.present ? "doc.text.fill" : "doc")
                                .foregroundStyle(f.present ? .orange : .secondary)
                            Text(f.name).font(.footnote.monospaced())
                            Spacer()
                            Text(f.present ? "存在" : "未预置")
                                .font(.caption2)
                                .foregroundStyle(f.present ? .orange : .secondary)
                        }
                    }
                }
            }

            // 操作
            Section {
                Button {
                    probe()
                } label: {
                    Label("检测逃逸", systemImage: "key.horizontal")
                }
                .disabled(probing)

                Button {
                    neuterAction()
                } label: {
                    Label("备份并清空 MDM 配置（绕过）", systemImage: "arrow.uturn.backward.badge.trash")
                }
                .disabled(probing || escapeMethod == nil)

                Button {
                    restoreAction()
                } label: {
                    Label("从备份还原", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(probing || !hasBackups)
            } footer: {
                Text("清空前自动备份到 Documents/SystemFileBackups/MDM；还原后请重启设备.仅供个人测试.")
            }

            // 日志
            if !logs.isEmpty {
                Section("日志") {
                    ForEach(Array(logs.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MDM 管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: { Text(alertBody) }
        .onAppear { hasBackups = MDMBypass.hasBackups() }
    }

    private func appendLog(_ line: String) {
        logs.append("· " + line)
    }

    private func probe() {
        probing = true
        logs.removeAll()
        fileStates = []
        let task = Task.detached(priority: .userInitiated) {
            MDMEscape.run(log: { line in
                Task { await MainActor.run { appendLog(line) } }
            })
        }
        Task {
            let result = await task.value
            await MainActor.run {
                probing = false
                if let r = result {
                    escapeMethod = r.method
                    escapeTarget = r.targetPath
                    refreshFiles(target: r.targetPath)
                } else {
                    escapeMethod = nil
                    escapeTarget = nil
                    alertTitle = "逃逸失败"
                    alertBody = "5 层策略均未通过 Darwin.open 实测.\n" +
                        "提示：侧载（LiveContainer）环境下系统沙盒策略可能拦截 ConfigurationProfiles；" +
                        "该绕过在 TrollStore 安装或越狱环境成功率更高.详见日志."
                    showAlert = true
                }
                hasBackups = MDMBypass.hasBackups()
            }
        }
    }

    private func refreshFiles(target: String) {
        var states: [(name: String, present: Bool)] = []
        for name in MDMPaths.knownFiles {
            let p = target.hasSuffix("/") ? target + name : target + "/" + name
            let fd = p.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            if fd >= 0 { Darwin.close(fd); states.append((name, true)) }
            else { states.append((name, false)) }
        }
        fileStates = states
    }

    private func neuterAction() {
        guard let target = escapeTarget else { return }
        probing = true
        Task.detached(priority: .userInitiated) {
            var written = 0
            var noEntry = 0
            var denied = 0
            for name in MDMPaths.knownFiles {
                switch MDMBypass.neuterOne(fileName: name, targetDir: target,
                                           backupRoot: MDMBypass.backupRoot,
                                           log: { line in
                                               Task { await MainActor.run { appendLog(line) } }
                                           }) {
                case .overwritten: written += 1
                case .notPresent: noEntry += 1
                case .denied: denied += 1
                }
            }
            await MainActor.run {
                probing = false
                hasBackups = MDMBypass.hasBackups()
                refreshFiles(target: target)
                if written > 0 {
                    alertTitle = "MDM 绕过完成"
                    alertBody = "\(written) 个描述文件已覆盖为空字典（已备份）.\n\(noEntry) 个未预置，\(denied) 个被拒.\n请重启设备使配置生效."
                } else if noEntry == MDMPaths.knownFiles.count {
                    alertTitle = "未加入 MDM 监管"
                    alertBody = "未检测到任何 MDM 描述文件，设备当前未受监管."
                } else {
                    alertTitle = "绕过失败"
                    alertBody = "\(denied) 个文件访问被拒（详见日志）."
                }
                showAlert = true
            }
        }
    }

    private func restoreAction() {
        guard let target = escapeTarget else { return }
        probing = true
        Task.detached(priority: .userInitiated) {
            let r = MDMBypass.restoreAll(targetDir: target)
            await MainActor.run {
                probing = false
                refreshFiles(target: target)
                alertTitle = "还原完成"
                alertBody = r.restored > 0
                    ? "已还原 \(r.restored) 个文件.\n\(r.error ?? "请重启设备使配置生效.")"
                    : "还原失败：\(r.error ?? "未知错误")"
                showAlert = true
            }
        }
    }
}
