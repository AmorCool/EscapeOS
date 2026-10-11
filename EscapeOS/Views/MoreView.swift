import SwiftUI

/// The "More" hub gathers secondary destinations that don't need their own
/// bottom-tab slots. Features are organized into logical sections for better
/// discoverability (v0.3.29: 22 features → 7 categorized sections).
///
/// v0.3.xxx：按巨魔录音机（TRApp）设计语言重做，与主页 `HomeView` **统一观感**
/// （原为 `List .insetGrouped` + `MoreCard`）：
/// - **页边距 20**（`AppTheme.pageInset`，原 16）；**大标题**走系统 `.large`（34pt bold）.
/// - **功能入口改 inset-grouped 卡片分组**（分段标题 + 连续圆角卡片），行 =
///   连续圆角图标底 + **17pt semibold** 标题 + **13pt footnote** 副标题 + 右 chevron
///   （与主页 `HomeRowLabel` 同一度量；分隔线左缩进对齐标题）.
/// - **强调色**统一到 `AppTheme.accent`（亮 `#005493` / 暗 `#76D6FF`，自适应）.
/// - 图标 `.hierarchical` 分层渲染；工具栏动作补触觉 `AppHaptics.tap()`.
///
/// ⚠️ 仅改样式：`isVisible(_:)` 热补丁过滤、`NavigationLazyView(item.destination)` 懒加载、
/// 两个 toolbar sheet（设备控制 / 设置）与 `MoreItem` 数据定义均**原样保留**.
struct MoreView: View {
    @ObservedObject private var hotfix = HotfixService.shared
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

    /// 热补丁接管点：feature.<id>.hidden 标志可隐藏任意功能入口
    private func isVisible(_ item: MoreItem) -> Bool {
        !hotfix.isFeatureHidden(item.id)
    }

    /// 分组定义（v0.3.29：22 个功能 → 7 个逻辑分区）.
    /// 每项 =（分段标题, 分段 SF Symbol, 脚注, 条目）.
    private var sections: [(header: String, symbol: String, footer: String?, items: [MoreItem])] {
        [
            // v0.3.412：漏洞利用 —— 置顶的普通导航行，点进去是二级选择页。
            ("漏洞利用", "ladybug.fill", nil, [
                MoreItem("exploit", "ladybug.fill", "漏洞利用",
                         "选择使用的漏洞利用",
                         ExploitSelectionView()),
            ]),
            ("配对文件", "key.horizontal", "重置/更换配对文件后从这里重新导入", [
                MoreItem("pairing-import", "key.horizontal", "配对文件导入",
                         "文件导入 / 剪贴板粘贴 / iOS 27 无线配对",
                         PairingSetupView(viewModel: appList)),
            ]),
            ("设备工具", "wrench.and.screwdriver", "需要配对文件 + LocalDevVPN 隧道", [
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
                MoreItem("ssh-debug", "terminal", "小型SSH服务",
                         "局域网无线连接诊断",
                         SSHDebugView()),
            ]),
            ("应用安装", "arrow.down.app.fill", "签名、安装与下载", [
                MoreItem("ipa-install", "arrow.down.app.fill", "IPA 侧载",
                         "签名安装 IPA",
                         IPAInstallView()),
                MoreItem("signed-ipa", "app.badge.checkmark", "IPA 安装",
                         "在线 / 覆盖安装已签名 IPA",
                         SignedIPAInstallView()),
                MoreItem("ipa-import", "square.and.arrow.down.on.square", "共享转换",
                         "导入他人分享的 IPA 并修补安装",
                         ImportView()),
                MoreItem("pairing-install", "tray.and.arrow.down.fill", "管理配对文件",
                         "把配对文件写入其它侧载工具（复用同一配对身份）",
                         PairingInstallView()),
            ]),
            ("文件管理", "folder.fill", nil, [
                MoreItem("file-browser", "folder.fill", "文件浏览器",
                         "浏览编辑设备文件",
                         FileBrowserRootView(appList: appList)),
                MoreItem("afc", "externaldrive.fill", "AFC 管理",
                         "AFC 文件浏览 / 导入导出文件",
                         AFCBrowserView()),
            ]),
            ("个性化", "paintbrush.fill", nil, [
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
            ("系统工具", "gearshape.2.fill", nil, [
                MoreItem("app-expiry", "calendar.badge.clock", "预置描述管理",
                         "App描述文件过期管理(.mobileprovision)",
                         AppExpiryView()),
                MoreItem("profile-install", "shield.lefthalf.filled", "发送描述文件",
                         "导入描述文件到本机",
                         ProfileInstallView()),
                MoreItem("profile-config", "list.bullet.rectangle.portrait.fill", "配置描述管理",
                         "iOS设置描述文件管理(.mobileprofile)",
                         ProfileConfigView()),
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
            ("账户与安全", "lock.shield.fill", nil, [
                MoreItem("certificates", "checkmark.seal.fill", "证书管理",
                         "管理开发证书",
                         CertificateView()),
                MoreItem("mdm-manage", "shield.lefthalf.filled.badge.checkmark", "MDM 管理",
                         "MDM 沙盒逃逸 / 描述文件备份还原（个人测试）",
                         MDMManageView()),
                MoreItem("memory", "memorychip", "增加内存限制",
                         "提高内存上限",
                         IncreaseMemoryView()),
            ]),
            ("数据与诊断", "chart.bar.doc.horizontal", nil, [
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
        ScrollView {
            VStack(spacing: 20) {
                ForEach(sections, id: \.header) { section in
                    moreSection(section)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    AppHaptics.tap()
                    showDeviceControl = true
                } label: {
                    Image(systemName: "power")
                        .imageScale(.large)
                }
                .accessibilityLabel("设备控制")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
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

    // MARK: - 分组渲染（TRApp inset-grouped 语言，与主页 `featureSection` 同款）

    /// 单个功能分组：分段标题 + 连续圆角卡片（行内 0 间距，靠 `rowDivider` 分隔）+ 可选脚注.
    /// 热补丁把整组都隐藏时不渲染该组（避免只剩一个空标题）.
    @ViewBuilder
    private func moreSection(_ section: (header: String, symbol: String, footer: String?, items: [MoreItem])) -> some View {
        let items = section.items.filter(isVisible)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(section.header, section.symbol)
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink {
                            NavigationLazyView(item.destination)
                        } label: {
                            MoreRowLabel(icon: item.icon, title: item.title, subtitle: item.subtitle)
                        }
                        .buttonStyle(.plain)
                        // 末行不附分隔线（组尾）
                        if item.id != items.last?.id {
                            rowDivider
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard(padding: 0)
                if let footer = section.footer {
                    Text(footer)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// 分段标题：SF Symbol + 次级字色小标题，位于卡片**上方**（inset-grouped 分段口径）.
    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .appSymbol()
            Text(title)
                .font(AppFont.captionEmphasis)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// 行分隔线：全宽发丝（`AppHairline`），左缩进对齐到图标底右侧
    /// （图标 30 + 间距 12 + 左内边距 14 = 56）.
    private var rowDivider: some View {
        AppHairline().padding(.leading, 56)
    }
}

/// 更多页功能行标签（TRApp inset-grouped 行语言）：连续圆角图标底 + 17pt semibold 标题 +
/// 13pt footnote 副标题 + 右侧 chevron. 与主页 `HomeRowLabel` 同一度量，仅作本页 `NavigationLink`
/// 的 label 使用.
private struct MoreRowLabel: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: icon, tint: AppTheme.accent, symbolSize: 16, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .appSymbol()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
