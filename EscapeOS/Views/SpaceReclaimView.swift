import SwiftUI

/// 「空间回收」板块总入口。
///
/// 用分段控件（分栏）在两类清理之间切换，二者底层共用同一个
/// `ReclaimAppView` 详情页：
/// - **常规清理**：扫描并回收**系统应用**的缓存与临时文件（`ReclaimTabView`）。
/// - **容器管理**：扫描并回收 **LiveContainer 内应用**的缓存与临时文件（`LiveCleanTabView`）。
///
/// 标题统一由本视图持有（"空间回收"），子视图不再设置各自标题，
/// 避免切到容器管理时大标题变成"容器管理"。
struct SpaceReclaimView: View {
    @ObservedObject var appList: AppListViewModel
    @State private var segment: ReclaimSegment = .regular

    enum ReclaimSegment: String, CaseIterable, Identifiable {
        case regular = "常规清理"
        case container = "容器管理"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 紧凑分段切换：高度压缩、与列表同背景，避免额外视觉层级。
            Picker("清理范围", selection: $segment) {
                ForEach(ReclaimSegment.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))

            Divider()

            switch segment {
            case .regular:
                ReclaimTabView(appList: appList)
            case .container:
                LiveCleanTabView(appList: appList)
            }
        }
        .navigationTitle("空间回收")
        .navigationBarTitleDisplayMode(.large)
    }
}
