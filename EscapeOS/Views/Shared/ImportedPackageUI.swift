import SwiftUI

// 共享转换 · 三个二级页（已导入 / 待修补 / 已修补）共用的小件与扫描入口。
//
// 抽出来只为**少写三遍**，不改任何既有行为：
//   · `ImportedPackageScanner`  —— 拿「本机已安装清单 + `Imports/` 磁盘现状」
//   · `ImportedPackageMonogram` —— 无真图标时的首字母块（TODO：接入真实图标）
//   · `PackageChip`             —— 胶囊标签（画法复用 IPADownloadManagerView / ImportView 的 `chip`）
//   · `ImportedPackage.Status` 的 `symbol` / `tint` —— 语义配色复用 `AppTheme` / `LocusTheme`

/// 三个二级页共用的扫描入口。
enum ImportedPackageScanner {

    /// 扫 `Imports/`，返回「已导入 / 已修补」两块。
    ///
    /// 「已安装」判定需要本机应用清单（`AppDiscovery`，依赖配对 / 隧道）；**查不到就传 nil**，
    /// 列表只落「待修补 / 已修补」，`isInstalled` 保持 nil，绝不凭空断言已安装。
    /// 扫描（判已安装时会解包读 bundleId）放后台，不卡主线程 —— 与 `ImportView.reloadPackages` 同型。
    static func scan() async -> ImportedPackageList.Listing {
        let installed: Set<String>? = await Task.detached(priority: .userInitiated) { () -> Set<String>? in
            do { return Set(try AppDiscovery().fetchInstalledApps().map(\.bundleIdentifier)) }
            catch { return nil }
        }.value
        return await Task.detached(priority: .userInitiated) {
            ImportedPackageList.scanListing(installedBundleIds: installed)
        }.value
    }
}

/// 无真图标时的首字母块（画法复用 `ImportView.monogram` / IPADownloadManagerView 的 monogram）。
///
/// TODO: 接入真实 App 图标 —— `ImportedPackage` 目前只有包名 / bundleId，没有图标来源。
///       可先解析包内 `Payload/*.app/AppIcon*`，或复用 `AppListViewModel.icons[bundleId]`（需先装到本机）。
struct ImportedPackageMonogram: View {
    let name: String
    var size: CGFloat = 44

    var body: some View {
        let letter = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.accent.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 胶囊标签（画法复用 `ImportView.chip`）。
struct PackageChip: View {
    let text: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

extension ImportedPackage.Status {
    /// 状态图标（语义对齐 `ImportView.ShareStage`：待修补 = clock / 已修补 = seal / 已安装 = check）。
    var symbol: String {
        switch self {
        case .awaitingRepair: return "clock"
        case .repaired:       return "checkmark.seal.fill"
        case .installed:      return "checkmark.circle.fill"
        }
    }

    /// 状态配色（复用 `AppTheme` / `LocusTheme` 语义色，不另造配色）。
    var tint: Color {
        switch self {
        case .awaitingRepair: return .orange
        case .repaired:       return LocusTheme.accent
        case .installed:      return LocusTheme.statusGood
        }
    }
}
