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

/// 爱思「应用修复安装」页 —— 照爱思 9.0 的「修复应用」入口，**设备级一键修复**.
///
/// ## 这个页面做什么
/// 点一次「开始修复」，按爱思修复流程经 AFC 把设备授权文件
/// `/iTunes_Control/iTunes/i4tool2.acc` 写进设备（失败重试 3 次、每次间隔 5 秒、单次超时 60 秒），
/// 并读回校验；用于修复爱思源应用的弹窗.
///
/// ## 为什么没有应用列表、没有下载台账
/// 爱思这个入口是**设备级**的：`QDialogFixApp` 没有应用选择列表，`CDeviceAppMgr` 拿到设备对象后
/// **无条件**写授权文件（plist 是设备级键：serial / udid / imei…，不是应用级）。
/// 故本页照此实现：不选应用、不查下载台账、不看共享账号白名单。
/// （证据：`P3_爱思助手_逆向/_简报/爱思9_修复弹窗_完整实现.md` §2.2）
///
/// ## 不移植
///   - 联网 `XX-AUTH` 授权（协议在 `idm_sync.dll` + 爱思服务端，iOS 侧拿不到）；
///   - 代理 App 容器里的 `AppInstall_SyncInfo.dat`（落点是 FairPlay 马甲包容器，读者不在我们手里）；
///   - 「兜底安装代理 App」（代理 App 是 FairPlay 加密马甲包，我们装不了）。
///
/// ## `auth` 字段
/// 照爱思的兜底逻辑用常量 `"1,2,3,4"`（爱思在「sync 成功但输出为空」时写这个值）；服务端
/// `XX-AUTH` 真值拿不到，故直接用爱思自己的兜底。是否生效取决于设备端爱思代理 App（读者）。
///
/// ## 界面口径
/// 只留必要操作与结论；路径 / `auth` 值 / 重试次数等**技术细节折叠进「技术详情」**，
/// 不铺在页面上（事实同时进 `LoginLogger`）.
struct I4AppFixView: View {
    @State private var busy = false
    @State private var repairError: String?
    @State private var report: I4AppFixService.Report?
    @State private var confirmShown = false
    /// 前置条件（事实查询，进入页与每次刷新时重读）.
    @State private var tunnelConnected = false
    @State private var hasPairing = false

    var body: some View {
        List {
            statusSection
            actionSection
            if busy { progressSection }
            if let report { resultSection(report) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("爱思应用修复安装")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(busy)
            }
        }
        .task { refresh() }
        .alert("确认修复", isPresented: $confirmShown) {
            Button("取消", role: .cancel) {}
            Button("开始修复") { Task { await runRepair() } }
        } message: {
            Text("将按爱思的做法写入设备授权文件，用于修复爱思源应用的弹窗.")
        }
    }

    // MARK: - 状态（就绪时一行；缺什么列什么）

    private var statusSection: some View {
        Section {
            if tunnelConnected && hasPairing {
                Label("设备已就绪", systemImage: "checkmark.circle.fill")
                    .font(AppFont.subheadline)
                    .foregroundStyle(AppTheme.trSuccess)
            }
            if !tunnelConnected {
                HStack(spacing: AppSpacing.row) {
                    Label("未连接本地隧道", systemImage: "wifi.slash")
                        .font(AppFont.subheadline)
                    Spacer()
                    Button("打开") { LocalDevVPN.openOrInstall() }
                        .buttonStyle(TintedButtonStyle())
                        .controlSize(.small)
                }
            }
            if !hasPairing {
                Label("未导入配对文件", systemImage: "doc.badge.ellipsis")
                    .font(AppFont.subheadline)
            }
        }
    }

    // MARK: - 修复（一键）

    private var actionSection: some View {
        Section {
            Button {
                confirmShown = true
            } label: {
                Text("开始修复").frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(!ready || busy)

            if let repairError {
                Text(repairError)
                    .font(AppFont.caption)
                    .foregroundStyle(AppTheme.danger)
            }
        }
    }

    private var ready: Bool { tunnelConnected && hasPairing }

    // MARK: - 进度

    private var progressSection: some View {
        Section {
            HStack(spacing: AppSpacing.row) {
                ProgressView()
                Text("正在修复，请稍候…")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 结果（结论一行 + 折叠的技术详情）

    private func resultSection(_ report: I4AppFixService.Report) -> some View {
        Section {
            Label(report.verdict,
                  systemImage: report.didWrite ? "checkmark.circle.fill" : "info.circle")
                .font(AppFont.subheadline)
                .foregroundStyle(report.didWrite ? AppTheme.trSuccess : .primary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("技术详情") {
                if let readBack = report.readBack, !readBack.entries.isEmpty {
                    ForEach(readBack.entries.map { I4AccRow(id: $0.key, value: $0.value) }) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.id).font(AppFont.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value)
                                .font(AppFont.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    Text("无读回内容.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(AppFont.caption)
        }
    }

    // MARK: - 数据加载 / 执行修复

    /// 只读前置条件（同步事实查询；进入页与刷新时调用）.
    private func refresh() {
        tunnelConnected = I4AppFixService.isTunnelConnected
        hasPairing = I4AppFixService.hasPairingFile
    }

    private func runRepair() async {
        guard ready, !busy else { return }
        busy = true
        repairError = nil
        report = nil
        do {
            // 服务层是阻塞调用（建隧道 + 读写 AFC），放后台；Report 经薄包装转移回主线程.
            // 已安装应用仅用于检测本机是否装了爱思代理 App（读者）——枚举也在后台做.
            let boxed = try await Task.detached(priority: .userInitiated) {
                let apps = (try? AppDiscovery().fetchInstalledApps()) ?? []
                return I4FixTransferBox(value: try await I4AppFixService.repair(installedApps: apps))
            }.value
            report = boxed.value
            refresh()
        } catch {
            repairError = error.localizedDescription
        }
        busy = false
    }
}
