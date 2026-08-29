import SwiftUI

/// 文件浏览器的根页面：按类别进入各个可浏览的根路径。
///
/// 移植自 Erosion 的 `FMRootView`，但入口按 EscapeOS 的实际情况做了扩充：
/// - Erosion 只列「应用容器 / 守护进程 / App 插件」三类，其余被 iOS 27 的版本门控挡住；
///   这里不做版本门控，全部列出 —— bad_query 签发失败时页面会原样报出错误，
///   比「干脆不显示」更容易判断是权限问题还是路径问题。
/// - 额外加了「应用安装目录」（看 .app 包）和「本应用文档」。
///
/// 本页面由「更多」页 push 进入 —— 不要嵌套 NavigationStack。
struct FileBrowserRootView: View {

    var body: some View {
        List {
            Section {
                ForEach(FileSystemRoots.entries) { entry in
                    NavigationLink {
                        FileBrowserView(rootPath: entry.id, title: entry.title)
                    } label: {
                        RootRow(
                            icon: entry.systemImage,
                            title: entry.title,
                            subtitle: entry.subtitle
                        )
                    }
                }
            } header: {
                Text("系统目录")
            } footer: {
                if FileSystemRoots.isRaveSupported {
                    Text("应用数据 / 守护进程 / App 插件 / .app 包通过 bad_query_list 枚举；App Group / System App Data / SystemGroup 需要 iOS 27 特定预览版。")
                } else {
                    Text("当前系统版本仅支持「应用数据 / 守护进程 / App 插件 / .app 包」。App Group / System App Data / SystemGroup 需要 iOS 27 特定预览版（24A5355q / 24A5370h / 24A5380h / 24A5390f）。")
                }
            }

            Section {
                NavigationLink {
                    FileBrowserView(
                        rootPath: FileSystemRoots.appDocuments,
                        title: "EscapeSpace 文档"
                    )
                } label: {
                    RootRow(
                        icon: "doc.fill",
                        title: "本应用文档",
                        subtitle: "备份、配对文件与导出物存放的位置"
                    )
                }
            } header: {
                Text("本应用")
            } footer: {
                Text("浏览文件时长按可复制、重命名、压缩；目录里可新建文件与文件夹。")
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0)
        .navigationTitle("文件浏览器")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct RootRow: View {
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
            }
            .padding(.vertical, 6)
        }
    }
}
