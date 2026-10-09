import SwiftUI

/// Swift 6：把 `I4AppFixService.Report` 从 `Task.detached` 边界**转移**回主线程时用的薄包装.
/// 与 `DeviceInfoView` 的 `DeviceInfoBox` 同款（不是共享，只转移）；命名刻意避开重名.
private struct I4FixTransferBox<T>: @unchecked Sendable { let value: T }

/// 读回内容的一行（`AccContent.entries` 是元组数组，元组不能做 `ForEach` 的身份，
/// 故映射成本结构；键即身份，plist 键唯一）.
private struct I4AccRow: Identifiable {
    let id: String
    let value: String
}

/// 爱思「应用修复安装」页 —— 把爱思 9.0 的「修复应用」入口移植过来.
///
/// ## 这个页面做什么
/// 只复刻爱思修复链里**可移植的那一段**：读设备上的 `/iTunes_Control/iTunes/i4tool2.acc`
/// （爱思授权凭据文件），并可选地按设备身份重写它（写入分支**默认关**）。**不移植**：
///   - 联网 `XX-AUTH` 授权（协议在 `idm_sync.dll` + 爱思服务端，iOS 侧拿不到）；
///   - 代理 App 容器里的 `AppInstall_SyncInfo.dat`（落点是 FairPlay 马甲包容器，读者不在我们手里）；
///   - 「兜底安装代理 App」（代理 App 是 FairPlay 加密马甲包，我们装不了）。
///
/// ## 诚实边界（页面必须如实展示，不美化）
/// 本功能**不能**解决 App Store 加密包的 `-42112`：`i4tool2.acc` 是爱思私有 plist，
/// iOS/installd/fairplay 不读它，其内容不含 FairPlay 密钥。写入分支用硬编码兜底 `auth`
/// （`"1,2,3,4"`），**效用未证实** —— 读者是设备端爱思代理 App，大概率不在本机.
///
/// ## 数据来源
/// 列表与修复逻辑都在 `I4AppFixService`（服务层，另一位同事实现；本页只**调用**、不修改）.
/// 列表口径：只列「疑似爱思源安装」的应用（下载台账 ∩ 共享账号白名单，取并集）.
struct I4AppFixView: View {
    @State private var installed: [InstalledApp] = []
    @State private var candidates: [I4AppFixService.Candidate] = []
    @State private var proxyBundleId: String?
    @State private var selectedId: String?
    /// 写入开关，**默认关**（与服务层 `repair(allowWrite:)` 的默认一致）：默认只读 + 展示.
    @State private var writeEnabled = false
    @State private var confirmShown = false
    @State private var loading = true
    @State private var busy = false
    @State private var loadError: String?
    @State private var repairError: String?
    @State private var report: I4AppFixService.Report?
    /// 前置条件（事实查询，进入页与每次刷新时重读）.
    @State private var tunnelConnected = false
    @State private var hasPairing = false

    var body: some View {
        List {
            precheckSection
            candidatesSection
            actionSection
            if busy { progressSection }
            if let report { resultSection(report) }
            disclaimerSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("爱思应用修复安装")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(busy)
            }
        }
        .task { await load() }
        .alert("确认修复", isPresented: $confirmShown) {
            Button("取消", role: .cancel) {}
            Button("开始修复") { Task { await runRepair() } }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - 前置状态

    private var precheckSection: some View {
        Section {
            if !tunnelConnected {
                VStack(alignment: .leading, spacing: 6) {
                    Label("未连接本地隧道（LocalDevVPN）", systemImage: "wifi.slash")
                        .font(.subheadline)
                    Text("本功能整条链依赖 RSD 隧道.请先打开 LocalDevVPN 连接后再试.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { LocalDevVPN.openOrInstall() } label: {
                        Text("打开 LocalDevVPN")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            if !hasPairing {
                Label("尚未导入配对文件", systemImage: "doc.badge.ellipsis")
                    .font(.subheadline)
            }
            if tunnelConnected && hasPairing {
                Label("隧道与配对文件就绪", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("前置状态")
        }
    }

    // MARK: - 候选应用

    private var candidatesSection: some View {
        Section {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取已安装应用…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本机没有检测到爱思源安装的应用.")
                        .font(.subheadline)
                    Text("识别口径：下载台账（经本 App 的爱思源下载记录）∪ 共享账号白名单"
                         + "（购买邮箱命中爱思共享账号）.两者都未命中则不列出.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        } header: {
            Text("疑似爱思源应用（\(candidates.count)）")
        } footer: {
            Text("修复写入的是设备级授权凭据文件 /\(I4AppFixService.accAFCPath)，与所选应用无关；"
                 + "选择仅用于确认目标确为爱思源应用.")
        }
    }

    private func candidateRow(_ candidate: I4AppFixService.Candidate) -> some View {
        let selected = candidate.bundleId == selectedId
        return Button {
            selectedId = selected ? nil : candidate.bundleId
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.unselected)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.subheadline)
                    Text(candidate.bundleId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let version = candidate.version {
                        Text("v\(version)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(sourceTag(candidate))
                        .font(.caption2)
                        .foregroundStyle(candidate.isSuspected ? AppTheme.pending : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 命中来源标签：两条都命中 = 已确证；仅共享账号 = 疑似.
    private func sourceTag(_ candidate: I4AppFixService.Candidate) -> String {
        if candidate.matchedBy.contains(.downloadLedger) && candidate.matchedBy.contains(.sharedAccount) {
            return "下载台账 + 共享账号"
        }
        if candidate.matchedBy.contains(.downloadLedger) {
            return "下载台账"
        }
        return "疑似（仅共享账号）"
    }

    // MARK: - 修复动作

    private var actionSection: some View {
        Section {
            Toggle(isOn: $writeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同时写入授权凭据（实验性）")
                        .font(.subheadline)
                    Text(writeEnabled
                         ? "将构造 8 键 plist 经 AFC 写入设备并读回校验.效用未证实."
                         : "默认只读：仅读取并展示设备上现有的凭据文件，零副作用.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(busy)

            Button {
                confirmShown = true
            } label: {
                Text(writeEnabled ? "修复并写入" : "读取并展示")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(!canRepair)

            if let hint = disabledHint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            if let repairError {
                Text(repairError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Label("修复", systemImage: "bandage")
        }
    }

    /// 为什么「修复」按钮不可点（前置校验未过时的如实提示）.
    private var disabledHint: String? {
        if busy { return nil }
        guard let candidate = selectedCandidate else {
            return "请先在上方选择要修复的爱思源应用."
        }
        if candidate.isSuspected {
            return "该应用仅由共享账号白名单命中，未确证为爱思源安装，已禁用修复."
        }
        if !tunnelConnected { return "未连接本地隧道（LocalDevVPN），已禁用修复." }
        if !hasPairing { return "尚未导入配对文件，已禁用修复." }
        return nil
    }

    private var selectedCandidate: I4AppFixService.Candidate? {
        candidates.first { $0.bundleId == selectedId }
    }

    private var canRepair: Bool {
        guard let candidate = selectedCandidate, !busy else { return false }
        return !candidate.isSuspected && tunnelConnected && hasPairing
    }

    private var confirmMessage: String {
        let target = selectedCandidate.map { "\($0.name)（\($0.bundleId)）" } ?? "所选应用"
        if writeEnabled {
            return "将对设备写入爱思授权凭据文件 /\(I4AppFixService.accAFCPath)."
                + "写入内容用硬编码兜底 auth，效用未证实，是否生效取决于设备端爱思代理 App."
                + "本功能不能解决 App Store 加密包的 -42112 问题."
        }
        return "将读取并展示设备上的 /\(I4AppFixService.accAFCPath)（不写入，零副作用），"
            + "用于确认 \(target) 是否已有爱思授权凭据.本功能不能解决 App Store 加密包的 -42112 问题."
    }

    // MARK: - 进度

    private var progressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(writeEnabled ? "正在写入并读回校验…" : "正在读取设备凭据文件…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("进度")
        }
    }

    // MARK: - 结果

    private func resultSection(_ report: I4AppFixService.Report) -> some View {
        Section {
            // ① 这次做了什么（如实）
            VStack(alignment: .leading, spacing: 4) {
                Text("这次做了什么")
                    .font(.subheadline.weight(.semibold))
                Text(actionSummary(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            // ② 读回内容
            if let readBack = report.readBack {
                if readBack.entries.isEmpty {
                    Text("读回内容为空（未解析出键值；format=\(readBack.format)，\(readBack.byteCount) bytes）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(readBack.entries.map { I4AccRow(id: $0.key, value: $0.value) }) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.id).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            } else {
                Text("设备上不存在 /\(I4AppFixService.accAFCPath)，无读回内容.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ③ 结论与补充说明（逐条事实 + 边界）
            VStack(alignment: .leading, spacing: 6) {
                Text(report.verdict)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            // ④ 显式标注不能解 -42112（服务层恒为 false，这里如实转述）
            Label(report.canResolveFairPlay42112
                  ? "可解决 -42112"
                  : "不能解决 App Store 加密包的 -42112",
                  systemImage: report.canResolveFairPlay42112 ? "checkmark.circle" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(report.canResolveFairPlay42112 ? AppTheme.success : AppTheme.danger)
        } header: {
            Label("结果", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func actionSummary(_ report: I4AppFixService.Report) -> String {
        if report.didWrite {
            let bytes = report.bytesWritten ?? 0
            let match = report.readBackMatchesWritten.map { $0 ? "读回一致" : "读回不一致" } ?? "未读回"
            return "已写入设备 /\(report.writePath)（\(bytes) bytes，\(match)）."
        }
        if let reason = report.notWrittenReason {
            return "未写入设备文件.\(reason)"
        }
        return "未写入设备文件（本次为只读分支）."
    }

    // MARK: - 常驻诚实说明

    private var disclaimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("本功能不能解决 App Store 加密包的 -42112", systemImage: "xmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.danger)
                Text("i4tool2.acc 是爱思私有 plist，iOS/installd/fairplay 不读它，其内容不含 FairPlay 密钥."
                     + "写入分支用硬编码兜底 auth（\(I4AppFixService.authFallback)），效用未证实，"
                     + "是否生效取决于设备端爱思代理 App（本机\(proxyBundleId == nil ? "未检测到" : "检测到")."
                     + "若只是想让应用能跑，请走自签重装或本机 sinf 通道.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } header: {
            Text("说明")
        }
    }

    // MARK: - 数据加载

    private func load() async {
        loading = true
        loadError = nil
        tunnelConnected = I4AppFixService.isTunnelConnected
        hasPairing = I4AppFixService.hasPairingFile
        do {
            // 枚举已安装应用是阻塞调用（建 RSD 隧道 + instproxy），放后台.
            let apps = try await Task.detached(priority: .userInitiated) {
                try AppDiscovery().fetchInstalledApps()
            }.value
            installed = apps
            // 台账读取按既有约定在主线程调用.
            candidates = I4AppFixService.candidates(installed: apps)
            proxyBundleId = I4AppFixService.proxyAppBundleId(in: apps)
            if let selectedId, !candidates.contains(where: { $0.bundleId == selectedId }) {
                self.selectedId = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    // MARK: - 执行修复

    private func runRepair() async {
        guard canRepair else { return }
        busy = true
        repairError = nil
        report = nil
        let allowWrite = writeEnabled
        let apps = installed
        do {
            // 服务层是阻塞调用（建隧道 + 读写 AFC），放后台；Report 经薄包装转移回主线程.
            let boxed = try await Task.detached(priority: .userInitiated) {
                I4FixTransferBox(value: try I4AppFixService.repair(allowWrite: allowWrite, installedApps: apps))
            }.value
            report = boxed.value
            // 读回后刷新前置状态（隧道可能在过程中断开）.
            tunnelConnected = I4AppFixService.isTunnelConnected
        } catch {
            repairError = error.localizedDescription
        }
        busy = false
    }
}
