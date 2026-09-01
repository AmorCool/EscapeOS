import SwiftUI

/// The "More" hub gathers secondary destinations that don't need their own
/// bottom-tab slots. Features are organized into logical sections for better
/// discoverability (v0.3.29: 22 features → 7 categorized sections).
struct MoreView: View {
    @ObservedObject var appList: AppListViewModel
    var onResetPairing: () -> Void
    @State private var showSettings = false
    @State private var showDeviceControl = false

    // MARK: - 分组数据

    private struct MoreItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let destination: AnyView

        init(_ id: String, _ icon: String, _ title: String, _ subtitle: String, _ dest: some View) {
            self.id = id
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
            self.destination = AnyView(dest)
        }
    }

    /// 分组定义（v0.3.29：22 个功能 → 7 个逻辑分区）
    private var sections: [(header: String, footer: String?, items: [MoreItem])] {
        [
            ("设备工具", "需要配对文件 + LocalDevVPN 隧道", [
                MoreItem("virtual-location", "location.fill", "虚拟定位",
                         "地图定位模拟，支持轨迹",
                         VirtualLocationView()),
                MoreItem("jit", "bolt.fill", "启用 JIT",
                         "以调试模式启动应用",
                         JITEnableView()),
                MoreItem("launch-apps", "arrow.up.forward.app.fill", "拉起应用",
                         "一键在前台拉起已装应用",
                         LaunchAppsView()),
                MoreItem("process-manager", "cpu", "进程管理",
                         "查看 / 挂起 / 结束设备进程",
                         ProcessManagerView()),
                MoreItem("pip-keepalive", "pip.enter", "PiP 保活",
                         "画中画保活防杀后台",
                         PiPKeepAliveView()),
                MoreItem("ssh-debug", "terminal", "SSH 调试",
                         "局域网无线连接诊断",
                         SSHDebugView()),
            ]),
            ("应用安装", "签名、安装与下载", [
                MoreItem("ipa-install", "arrow.down.app.fill", "IPA 侧载",
                         "签名安装 IPA",
                         IPAInstallView()),
                MoreItem("signed-ipa", "app.badge.checkmark", "IPA 安装",
                         "在线 / 覆盖安装已签名 IPA",
                         SignedIPAInstallView()),
                MoreItem("appstore", "cart.fill", "App Store 下载",
                         "搜索下载正版 IPA",
                         AppStoreDownloadView()),
                MoreItem("pairing-install", "tray.and.arrow.down.fill", "配置导入",
                         "写入本机配对文件到应用",
                         PairingInstallView()),
            ]),
            ("文件管理", nil, [
                MoreItem("file-browser", "folder.fill", "文件浏览器",
                         "浏览编辑设备文件",
                         FileBrowserRootView(appList: appList)),
                MoreItem("afc", "externaldrive.fill", "AFC 管理",
                         "AFC 文件浏览 / 导入导出文件",
                         AFCBrowserView()),
            ]),
            ("个性化", nil, [
                MoreItem("wallpaper", "photo.fill.on.rectangle.fill", "壁纸",
                         "导入壁纸包",
                         WallpaperView()),
                MoreItem("dialer", "circle.grid.3x3.fill", "拨号器主题",
                         "替换拨号键盘主题",
                         DialerThemeView()),
                MoreItem("ringtones", "music.note.list", "铃声管理",
                         "导入 / 导出铃声",
                         RingtonesView()),
            ]),
            ("系统工具", nil, [
                MoreItem("app-expiry", "calendar.badge.clock", "描述文件管理",
                         "描述文件过期管理",
                         AppExpiryView()),
                MoreItem("profile-install", "shield.lefthalf.filled", "发送描述文件",
                         "导入描述文件到本机",
                         ProfileInstallView()),
                MoreItem("ipcc", "antenna.radiowaves.left.and.right", "IPCC 安装",
                         "导入运营商 .ipcc 配置",
                         IPCCInstallView()),
                MoreItem("ddi", "iphone.and.arrow.forward", "开发者镜像",
                         "下载开发者镜像",
                         DDIDownloadView()),
                MoreItem("kernelcache", "cpu.fill", "下载 KernelCache",
                         "下载内核缓存",
                         KernelCacheView()),
                MoreItem("domain-blocker", "shield.fill", "屏蔽域名",
                         "DNS 屏蔽域名",
                         DomainBlockerView()),
            ]),
            ("账户与安全", nil, [
                MoreItem("certificates", "checkmark.seal.fill", "证书管理",
                         "管理开发证书",
                         CertificateView()),
                MoreItem("memory", "memorychip", "增加内存限制",
                         "提高内存上限",
                         IncreaseMemoryView()),
            ]),
            ("数据与诊断", nil, [
                MoreItem("backups", "externaldrive.fill.badge.timemachine", "备份",
                         "备份恢复管理",
                         BackupsListView(appList: appList)),
                MoreItem("crash-logs", "chart.bar.doc.horizontal", "崩溃分析",
                         "崩溃日志分析",
                         CrashLogView()),
                MoreItem("configurations", "checklist", "配置管理",
                         "系统配置管理",
                         ConfigurationsView()),
            ]),
        ]
    }

    var body: some View {
        List {
            ForEach(sections, id: \.header) { section in
                Section {
                    ForEach(section.items) { item in
                        NavigationLink(destination: NavigationLazyView(item.destination)) {
                            MoreCard(
                                icon: item.icon,
                                title: item.title,
                                subtitle: item.subtitle
                            )
                        }
                    }
                } header: {
                    Text(section.header)
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                        .foregroundColor(.secondary)
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showDeviceControl = true
                } label: {
                    Image(systemName: "power")
                        .imageScale(.large)
                }
                .accessibilityLabel("设备控制")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
            }
        }
        .sheet(isPresented: $showDeviceControl) {
            NavigationView {
                DeviceControlView()
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsForm(onResetPairing: onResetPairing)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
    }
}

/// A single card row used inside the "More" hub. Matches the InfoActionCard
/// visual language but is laid out as a tappable row with a trailing chevron.
struct MoreCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 强调色用 .blue，不用 AppTheme.accent（暖橙在浅色玻璃上显棕）。
            AppRowIcon(systemName: icon, tint: .blue, symbolSize: 20, frameSize: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}
