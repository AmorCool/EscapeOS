import SwiftUI

/// The "More" hub gathers secondary destinations that don't need their own
/// bottom-tab slots. It uses the same card/banner visual language as the rest
/// of the app (shared icon tile + title + subtitle) instead of a plain list.
struct MoreView: View {
    @ObservedObject var appList: AppListViewModel
    var onResetPairing: () -> Void

    var body: some View {
        List {
            Section {
                NavigationLink(destination: WallpaperView()) {
                    MoreCard(
                        icon: "photo.fill.on.rectangle.fill",
                        title: "壁纸",
                        subtitle: "导入并应用自定义 .tendies 壁纸包（PosterBoard）。"
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
                        icon: "globe.badge.xmark",
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

                NavigationLink(destination: SettingsForm(onResetPairing: onResetPairing)) {
                    MoreCard(
                        icon: "gearshape.fill",
                        title: "设置",
                        subtitle: "调整隧道 IP、重置配对文件、查看版本与限制说明。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
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
            AppRowIcon(systemName: icon, tint: AppTheme.accent, symbolSize: 20, frameSize: 36)

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

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.vertical, 6)
    }
}
