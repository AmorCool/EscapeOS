import Foundation
import SwiftUI
import Network

/// 连接诊断（移植自 SideStore Health Check，适配本仓 LocalDevVPN + TunnelContext）.
///
/// 用途：真机上打开此页即知「每一步到底通不通」，替代靠猜排查.
/// 数据全部来自**本仓实际使用的代码路径**，不是模拟值.
@MainActor
final class TunnelHealthViewModel: ObservableObject {
    // ── 网络 ──
    @Published var wifiSatisfied = false
    // ── 隧道 ──
    @Published var utunAvailable = false
    @Published var targetIP = ""
    @Published var candidatePeers: [String] = []
    @Published var targetReachable = false
    @Published var anyPeerReachable = false
    // ── 配对 ──
    @Published var pairingFileExists = false
    // ── Anisette ──
    @Published var anisetteReady = false
    @Published var anisetteStatus = ""
    // ── 接口列表 ──
    @Published var interfaces: [(name: String, family: Int32, address: String)] = []
    @Published var loaded = false

    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let satisfied: Bool?
        let optional: Bool

        init(_ title: String, _ subtitle: String, _ satisfied: Bool?, optional: Bool = false) {
            self.title = title; self.subtitle = subtitle; self.satisfied = satisfied; self.optional = optional
        }
    }

    func refresh() async {
        // 网络
        wifiSatisfied = CellularTunnelManager.isWiFiSatisfied(timeout: 0.5)

        // 隧道
        utunAvailable = LocalDevVPN.isConnected
        targetIP = LocalDevVPN.targetIP
        candidatePeers = LocalDevVPN.candidateTunnelPeers()
        targetReachable = LocalDevVPN.isReachable(ip: targetIP, timeout: 1.0)
        anyPeerReachable = LocalDevVPN.isAnyCandidateReachable(timeout: 0.5)

        // 配对
        pairingFileExists = TunnelContext.shared().hasPairingFile()

        // Anisette
        let readiness = OnDeviceAnisetteManager.shared.readiness()
        anisetteReady = readiness.isReady
        anisetteStatus = OnDeviceAnisetteManager.shared.readinessText

        // 接口列表
        interfaces = LocalDevVPN.allInterfaces()
        loaded = true
    }

    /// 按 SideStore Health Check 语言输出的诊断行.
    var rows: [Row] {
        var result: [Row] = []
        result.append(Row("网络", wifiSatisfied ? "Wi-Fi 已连接" : "无 Wi-Fi", wifiSatisfied))
        result.append(Row("utun 隧道接口", utunAvailable ? "存在" : "不存在", utunAvailable))
        result.append(Row(
            "目标对端可达（\(targetIP):49152）",
            targetReachable ? "可达" : "不可达",
            targetReachable))
        if candidatePeers.count > 1 {
            result.append(Row(
                "任一候选可达",
                anyPeerReachable ? "可达（\(candidatePeers.joined(separator: " / "))）" : "全部不可达",
                anyPeerReachable, optional: true))
        }
        result.append(Row(
            "配对文件",
            pairingFileExists ? "已导入" : "未导入",
            pairingFileExists))
        result.append(Row(
            "本机 Anisette",
            anisetteStatus,
            anisetteReady, optional: true))
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
                            if let s = row.satisfied {
                                Image(systemName: s ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(s ? .green : .red)
                                    .font(.title3)
                            } else {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundColor(.gray).font(.title3)
                            }
                        }
                    }
                }

                Section(header: Text("候选对端")) {
                    if viewModel.candidatePeers.isEmpty {
                        Text("无候选").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.candidatePeers, id: \.self) { peer in
                            HStack {
                                Text(peer).font(.system(.body, design: .monospaced))
                                Spacer()
                                if peer == viewModel.targetIP {
                                    Text("当前目标").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("网络接口")) {
                    ForEach(viewModel.interfaces, id: \.address) { iface in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(iface.name).fontWeight(.semibold)
                                Spacer()
                                Text(iface.family == AF_INET ? "IPv4" : "IPv6")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(iface.address)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
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
}
