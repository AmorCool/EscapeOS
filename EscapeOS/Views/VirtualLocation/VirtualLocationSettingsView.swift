import SwiftUI

/// 虚拟定位页设置：配对状态 / 隧道 / LocalDevVPN / 保活说明。
/// 配对文件与 EscapeSpace「更多 → 应用 / 设置」共用 Documents/pairingFile.plist。
struct VirtualLocationSettingsView: View {
    @ObservedObject private var session = SpoofSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tunnelIP = LocalDevVPN.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var tunnelConnected = LocalDevVPN.isConnected
    @State private var showImportGuide = false
    @Environment(\.scenePhase) private var scenePhase

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(session.hasPairing ? "已导入配对文件" : "未导入配对文件")
                    } icon: {
                        Image(systemName: session.hasPairing ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(session.hasPairing ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }

                    Button("如何导入配对文件") {
                        showImportGuide = true
                    }
                    .disabled(session.hasPairing)

                    if session.hasPairing {
                        Button("重置配对文件", role: .destructive) {
                            TunnelContext.shared.resetPairingFile()
                            session.lastError = nil
                        }
                    }
                } header: {
                    Text("开发者配对")
                } footer: {
                    Text("需要 idevice_pair 生成的 RPPairing 格式配对文件（.mobiledevicepairing）。已导入则此处直接可用，无需重复导入。")
                }

                Section {
                    TextField("设备隧道 IP", text: $tunnelIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveTunnelIP() }
                    LabeledContent("状态") {
                        Text(tunnelConnected ? "已连接" : "未连接")
                            .foregroundStyle(tunnelConnected ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }
                    Button("保存隧道 IP") {
                        saveTunnelIP()
                    }
                    Button {
                        if localDevVPNInstalled {
                            LocalDevVPN.openInstalled()
                        } else {
                            LocalDevVPN.openAppStore()
                        }
                    } label: {
                        Label(
                            localDevVPNInstalled ? "打开 LocalDevVPN" : "获取 LocalDevVPN（App Store）",
                            systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                        )
                    }
                } header: {
                    Text("隧道")
                } footer: {
                    Text("传送前先连接 LocalDevVPN。默认隧道 IP 为 10.7.0.1。建议在 Wi-Fi 下开始模拟，之后可切回蜂窝网络继续。")
                }

                Section("隐私") {
                    Text("完全在设备本地运行。收藏与最近记录仅存于 UserDefaults，无任何分析、账号或上传。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("引擎", value: "idevice DVT 定位模拟")
                    Text("虚拟定位功能移植自开源项目 locus（MIT）：定位注入通过 idevice FFI 调用 Apple 开发者定位模拟服务，无需越狱或漏洞。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("虚拟定位设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        saveTunnelIP()
                        dismiss()
                    }
                }
            }
            .onAppear {
                localDevVPNInstalled = LocalDevVPN.isInstalled
                tunnelConnected = LocalDevVPN.isConnected
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    localDevVPNInstalled = LocalDevVPN.isInstalled
                    tunnelConnected = LocalDevVPN.isConnected
                }
            }
            .alert("导入配对文件", isPresented: $showImportGuide) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请退出本页，进入底部「应用」标签页，使用右上角的配对导入功能导入 idevice_pair 生成的配对文件；或使用 iPASide 安装时附带配对文件。导入后回到这里即可开始虚拟定位。")
            }
        }
    }

    private func saveTunnelIP() {
        let trimmed = tunnelIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: "TunnelDeviceIP")
        }
        tunnelIP = LocalDevVPN.targetIP
    }
}
