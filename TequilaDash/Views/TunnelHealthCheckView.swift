import Foundation
import SwiftUI

/// 连接诊断（移植自 SideStore Health Check，适配本仓 LocalDevVPN + TunnelContext）.
///
/// 用途：真机上打开此页即知「每一步到底通不通」，替代靠猜排查.
/// 数据全部来自**本仓实际使用的代码路径**，不是模拟值.
///
/// ## 并发口径（Swift 6 严格并发）
/// 探测本身是**阻塞**的（`NWPathMonitor` 等首个路径回调、TCP `poll` 最多 1s），
/// 所以整段放在 `Task.detached` 里跑，**不占主线程**；结果用一个 `Sendable` 快照
/// 传回主 actor 再赋值. 否则在 `@MainActor` 上直接调会卡住界面.
@MainActor
final class TunnelHealthViewModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var loaded = false

    /// 探测结果快照（`Sendable`：全是值类型，可安全跨隔离域传递）.
    struct Snapshot: Sendable {
        var wifiSatisfied = false
        var utunAvailable = false
        var targetIP = ""
        var candidatePeers: [String] = []
        var targetReachable = false
        var anyPeerReachable = false
        var pairingFileExists = false
        var anisetteReady = false
        var anisetteStatus = ""
        var interfaces: [LocalDevVPN.InterfaceInfo] = []
    }

    /// 一行诊断结果.
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let satisfied: Bool?
        /// `true` = 该项失败不阻塞主流程（显示为橙色减号而非红叉）.
        let optional: Bool

        init(_ title: String, _ subtitle: String, _ satisfied: Bool?, optional: Bool = false) {
            self.id = title
            self.title = title
            self.subtitle = subtitle
            self.satisfied = satisfied
            self.optional = optional
        }
    }

    func refresh() async {
        // 阻塞探测（NWPathMonitor 首个回调 / TCP poll）放后台，不占主线程.
        var probe = await Task.detached(priority: .userInitiated) { Self.probe() }.value
        // Anisette 就绪只是文件与钥匙串的存在性检查（微秒级），留在主 actor，
        // 避免依赖 `OnDeviceAnisetteManager` 的隔离域假设.
        let mgr = OnDeviceAnisetteManager.shared
        probe.anisetteReady = mgr.readiness().isReady
        probe.anisetteStatus = mgr.readinessText
        snapshot = probe
        loaded = true
    }

    /// 阻塞探测集中在这里，**不在主 actor 上跑**.
    private nonisolated static func probe() -> Snapshot {
        var s = Snapshot()
        // 网络（NWPathMonitor 等首个回调，最多 0.5s）
        s.wifiSatisfied = CellularTunnelManager.isWiFiSatisfied(timeout: 0.5)
        // 隧道
        s.utunAvailable = LocalDevVPN.isConnected
        s.targetIP = LocalDevVPN.targetIP
        s.candidatePeers = LocalDevVPN.candidateTunnelPeers()
        s.targetReachable = LocalDevVPN.isReachable(ip: s.targetIP, timeout: 1.0)
        s.anyPeerReachable = LocalDevVPN.isAnyCandidateReachable(timeout: 0.5)
        // 配对文件
        // 注意：`TunnelContext.shared` 是 ObjC 类属性（`@property (class, readonly)`），
        // Swift 侧导入为**属性**而非方法 —— 写 `shared()` 会报
        // 「cannot call value of non-function type 'TunnelContext'」.
        s.pairingFileExists = TunnelContext.shared.hasPairingFile
        // 接口列表
        s.interfaces = LocalDevVPN.allInterfaces()
        return s
    }

    /// 按 SideStore Health Check 语言输出的诊断行.
    var rows: [Row] {
        let s = snapshot
        var result: [Row] = []
        result.append(Row("网络", s.wifiSatisfied ? "Wi-Fi 已连接" : "无 Wi-Fi", s.wifiSatisfied))
        result.append(Row("utun 隧道接口", s.utunAvailable ? "存在" : "不存在", s.utunAvailable))
        result.append(Row(
            "目标对端可达（\(s.targetIP):49152）",
            s.targetReachable ? "可达" : "不可达",
            s.targetReachable))
        if s.candidatePeers.count > 1 {
            result.append(Row(
                "任一候选可达",
                s.anyPeerReachable ? "可达（\(s.candidatePeers.joined(separator: " / "))）" : "全部不可达",
                s.anyPeerReachable, optional: true))
        }
        result.append(Row("配对文件", s.pairingFileExists ? "已导入" : "未导入", s.pairingFileExists))
        result.append(Row("本机 Anisette", s.anisetteStatus, s.anisetteReady, optional: true))
        return result
    }
}

/// 诊断页：全宽行 + 图标判定，照 SideStore Health CheckView 结构.
struct TunnelHealthCheckView: View {
    @StateObject private var viewModel = TunnelHealthViewModel()

    var body: some View {
        List {
            if !viewModel.loaded {
                Section { ProgressView("正在检查…") }
            } else {
                Section(header: Text("诊断结果")) {
                    ForEach(viewModel.rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.body)
                                Text(row.subtitle).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            statusIcon(row)
                        }
                    }
                }

                Section(header: Text("候选对端")) {
                    if viewModel.snapshot.candidatePeers.isEmpty {
                        Text("无候选").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.snapshot.candidatePeers, id: \.self) { peer in
                            HStack {
                                Text(peer).font(.system(.body, design: .monospaced))
                                Spacer()
                                if peer == viewModel.snapshot.targetIP {
                                    Text("当前目标").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("网络接口")) {
                    if viewModel.snapshot.interfaces.isEmpty {
                        Text("未枚举到接口").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.snapshot.interfaces) { iface in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(iface.name).fontWeight(.semibold)
                                    Spacer()
                                    Text(iface.isIPv4 ? "IPv4" : "IPv6")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(iface.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Button("重新检查") {
                    Task { await viewModel.refresh() }
                }
            }
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private func statusIcon(_ row: TunnelHealthViewModel.Row) -> some View {
        if let satisfied = row.satisfied {
            if satisfied {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title3)
            } else if row.optional {
                // 可选项失败不阻塞主流程：橙色减号，与 SideStore 的呈现一致.
                Image(systemName: "minus.circle.fill").foregroundColor(.orange).font(.title3)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.title3)
            }
        } else {
            Image(systemName: "questionmark.circle.fill").foregroundColor(.gray).font(.title3)
        }
    }
}
