import SwiftUI

/// The "More" hub gathers secondary destinations that don't need their own
/// bottom-tab slots. It uses the same card/banner visual language as the rest
/// of the app (shared icon tile + title + subtitle) instead of a plain list.
struct MoreView: View {
    @ObservedObject var appList: AppListViewModel
    var onResetPairing: () -> Void
    @State private var showSettings = false
    @State private var showDeviceControl = false

    var body: some View {
        List {
                Section {
                    NavigationLink(destination: VirtualLocationView()) {
                        MoreCard(
                            icon: "location.fill",
                            title: "虚拟定位",
                            subtitle: "在地图上放置图钉或规划轨迹，模拟设备定位（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: JITEnableView()) {
                        MoreCard(
                            icon: "bolt.fill",
                            title: "启用 JIT",
                            subtitle: "以调试模式启动应用，为其启用 JIT 权限（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: LaunchAppsView()) {
                        MoreCard(
                            icon: "arrow.up.forward.app.fill",
                            title: "拉起应用",
                            subtitle: "列出全部已安装应用，一键在前台拉起（普通启动，不启用 JIT）。"
                        )
                    }

                    NavigationLink(destination: AppExpiryView()) {
                        MoreCard(
                            icon: "calendar.badge.clock",
                            title: "描述文件管理",
                            subtitle: "查看所有描述文件的过期时间，支持按证书分组与批量删除。"
                        )
                    }

                    NavigationLink(destination: CertificateView()) {
                        MoreCard(
                            icon: "checkmark.seal.fill",
                            title: "证书管理",
                            subtitle: "登录 Apple ID，查看并吊销账号下的 iOS 开发证书（纯网络操作，无需隧道）。"
                        )
                    }

                    NavigationLink(destination: PairingInstallView()) {
                        MoreCard(
                            icon: "tray.and.arrow.down.fill",
                            title: "配置导入",
                            subtitle: "把配对文件写入已安装的 SideStore / LiveContainer / Feather 等应用，复用同一份配对身份。"
                        )
                    }

                    NavigationLink(destination: IPAInstallView()) {
                        MoreCard(
                            icon: "arrow.down.app.fill",
                            title: "IPA 侧载",
                            subtitle: "签名并安装 IPA 到设备（Apple ID 登录 + LocalDevVPN 隧道）。"
                        )
                    }

                    NavigationLink(destination: AppStoreDownloadView()) {
                        MoreCard(
                            icon: "cart.fill",
                            title: "App Store 下载",
                            subtitle: "登录 App Store 账户，搜索并下载正版 IPA（含历史版本），下载后交给「IPA 安装」在线安装 —— 与爱思助手同款流程。"
                        )
                    }

                    NavigationLink(destination: SignedIPAInstallView()) {
                        MoreCard(
                            icon: "app.badge.checkmark",
                            title: "IPA 安装",
                            subtitle: "在线安装已签名 IPA（App Store / Apple ID 包）：新装、覆盖升级/降级安装，爱思同款通道，无需再次签名（需 LocalDevVPN 隧道）。"
                        )
                    }

                    NavigationLink(destination: ProcessManagerView()) {
                        MoreCard(
                            icon: "cpu",
                            title: "进程管理",
                            subtitle: "查看设备运行中的进程，支持挂起 / 恢复 / 结束（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: WallpaperView()) {
                        MoreCard(
                            icon: "photo.fill.on.rectangle.fill",
                            title: "壁纸",
                            subtitle: "导入并应用自定义 .tendies 壁纸包（PosterBoard）。"
                        )
                    }

                    NavigationLink(destination: DialerThemeView()) {
                        MoreCard(
                            icon: "circle.grid.3x3.fill",
                            title: "拨号器主题",
                            subtitle: "替换电话 App 的拨号键盘图片，支持 .passthm / .zip 主题包或直接多选 PNG。"
                        )
                    }

                    NavigationLink(destination: RingtonesView()) {
                        MoreCard(
                            icon: "music.note.list",
                            title: "铃声管理",
                            subtitle: "导入 / 导出 / 删除用户铃声，并可提取系统提示音（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: FileBrowserRootView(appList: appList)) {
                        MoreCard(
                            icon: "folder.fill",
                            title: "文件浏览器",
                            subtitle: "浏览并编辑设备上的任意容器：应用数据、守护进程、App 插件、.app 包等。"
                        )
                    }

                    NavigationLink(destination: AFCBrowserView()) {
                        MoreCard(
                            icon: "externaldrive.fill",
                            title: "AFC 管理",
                            subtitle: "经本地隧道浏览设备文件系统（初始 /var/mobile/media）：下载导出、上传、移动、新建目录、删除（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: KernelCacheView()) {
                        MoreCard(
                            icon: "cpu.fill",
                            title: "下载 KernelCache",
                            subtitle: "从 Apple CDN 的 IPSW 中按偏移只下载 kernelcache 内核缓存文件（约 20MB，纯网络、零权限），与越狱工具从设备读取的是同一份文件。"
                        )
                    }


                    NavigationLink(destination: ProfileInstallView()) {
                        MoreCard(
                            icon: "shield.lefthalf.filled",
                            title: "发送描述文件",
                            subtitle: "导入 .mobileconfig 描述文件（屏蔽 iOS 更新、Wi-Fi、VPN 等）一键发送到本机，去「设置 → 通用 → VPN 与设备管理」安装，与爱思助手同款原理。"
                        )
                    }

                    NavigationLink(destination: CrashLogView()) {
                        MoreCard(
                            icon: "chart.bar.doc.horizontal",
                            title: "崩溃分析",
                            subtitle: "查看设备崩溃与诊断日志（对应「分析与改进」），支持批量选择导出 / 删除（需配对文件 + LocalDevVPN）。"
                        )
                    }

                    NavigationLink(destination: IPCCInstallView()) {
                        MoreCard(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "IPCC 安装",
                            subtitle: "导入运营商配置文件（.ipcc）安装到 Carrier Bundles Overrides，重启后生效。"
                        )
                    }

                    NavigationLink(destination: DDIDownloadView()) {
                        MoreCard(
                            icon: "iphone.and.arrow.forward",
                            title: "开发者镜像",
                            subtitle: "下载 DDI / DMG 镜像并打包为 DMG.zip。"
                        )
                    }

                    NavigationLink(destination: DomainBlockerView()) {
                        MoreCard(
                            icon: "shield.fill",
                            title: "屏蔽域名",
                            subtitle: "生成 DNS 描述文件，按需屏蔽任意域名（含 iOS 更新）。"
                        )
                    }

                    NavigationLink(destination: BackupsListView(appList: appList)) {
                        MoreCard(
                            icon: "externaldrive.fill.badge.timemachine",
                            title: "备份",
                            subtitle: "查看、恢复或导出已创建的 EscapeSpace 备份归档。"
                        )
                    }

                    NavigationLink(destination: ConfigurationsView()) {
                        MoreCard(
                            icon: "checklist",
                            title: "配置管理",
                            subtitle: "锁屏页脚与监督模式等系统配置（MDM），iOS 26 下支持读取与备份。"
                        )
                    }

                    NavigationLink(destination: IncreaseMemoryView()) {
                        MoreCard(
                            icon: "memorychip",
                            title: "增加内存限制",
                            subtitle: "登录 Apple ID 并配置 Anisette，为 App 开启 INCREASED_MEMORY_LIMIT。"
                        )
                    }
                }
            }
            .listStyle(.plain)
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.vertical, 10)
    }
}
