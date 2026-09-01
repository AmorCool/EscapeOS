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
                         "在地图上放置图钉或规划轨迹，模拟设备定位。",
                         VirtualLocationView()),
                MoreItem("jit", "bolt.fill", "启用 JIT",
                         "以调试模式启动应用，为其启用 JIT 权限。",
                         JITEnableView()),
                MoreItem("launch-apps", "arrow.up.forward.app.fill", "拉起应用",
                         "列出全部已安装应用，一键在前台拉起。",
                         LaunchAppsView()),
                MoreItem("process-manager", "cpu", "进程管理",
                         "查看设备运行中的进程，支持挂起 / 恢复 / 结束。",
                         ProcessManagerView()),
            ]),
            ("应用安装", "签名、安装与下载", [
                MoreItem("ipa-install", "arrow.down.app.fill", "IPA 侧载",
                         "签名并安装 IPA 到设备。",
                         IPAInstallView()),
                MoreItem("signed-ipa", "app.badge.checkmark", "IPA 安装",
                         "在线安装已签名 IPA：新装、覆盖升级/降级。",
                         SignedIPAInstallView()),
                MoreItem("appstore", "cart.fill", "App Store 下载",
                         "登录账户搜索并下载正版 IPA（含历史版本）。",
                         AppStoreDownloadView()),
                MoreItem("pairing-install", "tray.and.arrow.down.fill", "配置导入",
                         "把配对文件写入 SideStore / LC / Feather 等应用。",
                         PairingInstallView()),
            ]),
            ("文件管理", nil, [
                MoreItem("file-browser", "folder.fill", "文件浏览器",
                         "浏览并编辑设备上的任意容器与目录。",
                         FileBrowserRootView(appList: appList)),
                MoreItem("afc", "externaldrive.fill", "AFC 管理",
                         "经本地隧道浏览设备文件系统：导出、上传、删除。",
                         AFCBrowserView()),
            ]),
            ("个性化", nil, [
                MoreItem("wallpaper", "photo.fill.on.rectangle.fill", "壁纸",
                         "导入并应用自定义 .tendies 壁纸包。",
                         WallpaperView()),
                MoreItem("dialer", "circle.grid.3x3.fill", "拨号器主题",
                         "替换电话 App 拨号键盘，支持主题包或 PNG。",
                         DialerThemeView()),
                MoreItem("ringtones", "music.note.list", "铃声管理",
                         "导入 / 导出 / 删除用户铃声。",
                         RingtonesView()),
            ]),
            ("系统工具", nil, [
                MoreItem("app-expiry", "calendar.badge.clock", "描述文件管理",
                         "查看描述文件过期时间，按证书分组与批量删除。",
                         AppExpiryView()),
                MoreItem("profile-install", "shield.lefthalf.filled", "发送描述文件",
                         "导入 .mobileconfig 描述文件一键发送到本机。",
                         ProfileInstallView()),
                MoreItem("ipcc", "antenna.radiowaves.left.and.right", "IPCC 安装",
                         "导入运营商配置文件（.ipcc），重启生效。",
                         IPCCInstallView()),
                MoreItem("ddi", "iphone.and.arrow.forward", "开发者镜像",
                         "下载 DDI / DMG 镜像并打包。",
                         DDIDownloadView()),
                MoreItem("kernelcache", "cpu.fill", "下载 KernelCache",
                         "从 Apple CDN 下载内核缓存文件。",
                         KernelCacheView()),
                MoreItem("domain-blocker", "shield.fill", "屏蔽域名",
                         "生成 DNS 描述文件，屏蔽任意域名。",
                         DomainBlockerView()),
            ]),
            ("账户与安全", nil, [
                MoreItem("certificates", "checkmark.seal.fill", "证书管理",
                         "查看并吊销 Apple ID 下的开发证书。",
                         CertificateView()),
                MoreItem("memory", "memorychip", "增加内存限制",
                         "为 App 开启 INCREASED_MEMORY_LIMIT。",
                         IncreaseMemoryView()),
            ]),
            ("数据与诊断", nil, [
                MoreItem("backups", "externaldrive.fill.badge.timemachine", "备份",
                         "查看、恢复或导出备份归档。",
                         BackupsListView(appList: appList)),
                MoreItem("crash-logs", "chart.bar.doc.horizontal", "崩溃分析",
                         "查看设备崩溃与诊断日志，批量导出/删除。",
                         CrashLogView()),
                MoreItem("configurations", "checklist", "配置管理",
                         "锁屏页脚与监督模式等系统配置。",
                         ConfigurationsView()),
            ]),
        ]
    }

    var body: some View {
        List {
            ForEach(sections, id: \.header) { section in
                Section {
                    ForEach(section.items) { item in
                        NavigationLink(destination: item.destination) {
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
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}
