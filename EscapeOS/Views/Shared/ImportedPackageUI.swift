import SwiftUI
import UIKit
import CryptoKit

// 共享转换 · 三个二级页（已导入 / 待修补 / 已修补）共用的小件与扫描入口。
//
// 抽出来只为**少写三遍**，不改任何既有行为：
//   · `ImportedPackageScanner`  —— 拿「本机已安装清单 + `Imports/` 磁盘现状」
//   · `ImportedPackageIconView` / `ImportedPackageIconStore` / `ImportedPackageIconExtractor`
//                              —— 从 IPA（zip）里提取真图标：缩略图与长按预览共用同一份
//   · `ImportedPackageMonogram` —— 读不出真图标时的首字母块（回落项）
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
/// 它是 `ImportedPackageIconView` 的**回落项**：从包内读不出图标时用它，绝不显示空白或
/// 加载失败样式的占位（字母块看着是有意设计）。
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

// MARK: - 应用图标（缩略图 / 长按预览共用同一份）

/// 列表行左侧的应用图标缩略图：有真图标就画，读不出回落首字母块。
///
/// `url` 是 `ImportedPackageIconStore` 给出的 `file://` 地址；为空 / 读不出时回落
/// `ImportedPackageMonogram`。缩略图与长按菜单里的「查看图标 / 提取图标」读的是**同一个地址**。
struct ImportedPackageIconView: View {
    let name: String
    let url: String?
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ImportedPackageMonogram(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) { load() }
    }

    /// 直接读本地缓存文件（`file://` 路径）—— 图标只有几十 KB，主线程同步读即可，
    /// 不走 `AsyncImage`（避免它对 `file` scheme 的额外不确定性）。
    private func load() {
        guard let url, !url.isEmpty, let path = URL(string: url)?.path else {
            image = nil
            return
        }
        image = UIImage(contentsOfFile: path)
    }
}

/// 图标落盘缓存 —— 把 `ImportedPackageIconExtractor` 解出来的 PNG 落一份到 Caches，
/// 对外只给 `file://` 地址。
///
/// **为什么落文件而不是只留内存**：长按菜单的「查看图标 / 提取图标」复用仓库既有的 URL 取图链
/// （`iconMenuItems` → `showIconPreview` / `IconExporter` → `PreviewImageLoader`），
/// 那条链只认 URL（`URLSession` 原生支持 `data` / `file` / `ftp` / `http` / `https` scheme），
/// 所以图标必须以 `file://` 地址给出 —— 这样缩略图、预览、保存拿到的是**同一份**图标，
/// 不必另写一套本地预览，也不会把「长按存图」做成第二份实现.
///
/// 文件名取包 id 的 MD5（跨进程稳定）；命中已存在的文件就直接返回，不再读 zip.
/// Caches 目录可被系统回收，丢了下次重新提取即可.
enum ImportedPackageIconStore {

    /// 取该包的图标地址（`file://…`）；读不出返回 nil，界面回落首字母块.
    static func iconURL(for package: ImportedPackage) -> String? {
        guard let ipaPath = package.originalPath ?? package.repairedPath else { return nil }
        let fileURL = cachedFileURL(key: package.id)
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL.absoluteString }
        guard let data = ImportedPackageIconExtractor.iconPNGData(ipaPath: ipaPath) else { return nil }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL.absoluteString
    }

    private static func cachedFileURL(key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPackageIcons", isDirectory: true)
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dir.appendingPathComponent("\(digest).png")
    }
}

/// 从 IPA（zip）里提取应用图标 PNG —— 本仓第一份「从 zip 取图标」的实现。
///
/// 依据是 `Info.plist` 的图标声明，口径与 `LiveContainerDiscovery.loadIconData` 一致
///（区别只是那边读**已解压目录**、这里读 **zip 内的条目**）：
///   · `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles` / `CFBundleIconName`
///   · 退到顶层 `CFBundleIconFiles` / `CFBundleIconName`
/// 先按声明名在 `Payload/<App>.app/` 下试 `@3x / @2x / 无后缀`（含 `-ipad` / `-iphone` 变体），
/// 都找不到就退到 app 包根目录下体积最大的 PNG。
///
/// 读不出（图标只编进 `Assets.car` / 包结构异常）返回 nil，由调用方回落首字母块 —— 不臆造.
enum ImportedPackageIconExtractor {

    static func iconPNGData(ipaPath: String) -> Data? {
        guard let reader = try? ZipReader(url: URL(fileURLWithPath: ipaPath)) else { return nil }
        defer { reader.close() }
        let names = reader.entryNames()
        guard let infoName = names.first(where: {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist")
        }),
        let infoData = try? reader.readEntry(named: infoName),
        let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
        let info = plist as? [String: Any] else { return nil }

        // `Payload/<App>.app/` —— Info.plist 所在 app 包的目录前缀。
        let appPrefix = String(infoName.dropLast("Info.plist".count))

        var declared: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] { declared.append(contentsOf: files) }
            if let name = primary["CFBundleIconName"] as? String { declared.append(name) }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { declared.append(contentsOf: files) }
        if let name = info["CFBundleIconName"] as? String { declared.append(name) }

        // 1) 按声明名找条目（含常见设备变体后缀）。
        let suffixes = ["@3x", "@2x", "", "-ipad@2x", "-iphone@3x", "-ipad@1x"]
        for name in declared where !name.isEmpty {
            for suffix in suffixes {
                let target = appPrefix + name + suffix + ".png"
                if let data = try? reader.readEntry(named: target), !data.isEmpty { return data }
            }
        }

        // 2) 兜底：app 包根目录（不含子目录）下体积最大的 PNG。
        let pngs = names.filter { name in
            guard name.hasPrefix(appPrefix), name.lowercased().hasSuffix(".png") else { return false }
            return !name.dropFirst(appPrefix.count).contains("/")
        }
        var best: (size: Int, data: Data)?
        for name in pngs {
            guard let entry = reader.entries[name] else { continue }
            if best == nil || entry.uncompressedSize > best!.size {
                if let data = try? reader.readEntry(named: name), !data.isEmpty {
                    best = (entry.uncompressedSize, data)
                }
            }
        }
        return best?.data
    }
}
