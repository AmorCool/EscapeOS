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
        try? FileManager.default.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL.absoluteString
    }

    /// 清掉「在 `Imports/` 里已找不到对应包」的图标缓存 —— 否则这个目录只增不删.
    ///
    /// 判据与写入用同一把钥匙：缓存文件名就是包 id（`originalPath ?? repairedPath`）的 MD5.
    /// 时机：`loadIcons()` 开始时（那时已能列出 `Imports/` 现状）.
    /// 不会误删：只要包还在 `Imports/`（原件或产物任一在），其 id 必落在保留集里；
    /// 只有包被移除、或 id 因修补改了落点（`original.ipa` → `repaired.ipa`）而变旧时，
    /// 旧文件才失去对应包而被清掉. Caches 目录本就可被系统回收，丢了下次重新提取即可.
    static func pruneStaleIcons() {
        let fm = FileManager.default
        // 读不出 `Imports/` 现状时**不清理** —— 「读不出来 ≠ 确定没有」，否则会把仍有效的图标误删.
        guard let keys = liveKeys() else { return }
        let dir = cacheDirectory()
        guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        let keep = Set(keys.map(digest(of:)))
        for f in files where f.pathExtension.lowercased() == "png" {
            if !keep.contains(f.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// `Imports/` 里**所有包**的 id 集合（原件 / 产物两种落点都算），只枚举目录、不读 zip.
    ///
    /// id 口径与 `ImportedPackageList.scanListing` 的 `make` 逐条对齐（原件优先，其次产物）：
    ///   · 新落点目录 `<名>/`：有产物 ⇒ 取原件（若在）否则产物；仅原件 ⇒ 取原件；
    ///   · 老平铺 `<名>.ipa`：有同名产物 ⇒ 取产物，否则取该 ipa；
    ///   · 产物仓库里原件已不在的 ⇒ 取产物.
    /// 任一枚举失败返回 nil（调用方据此跳过清理，不误删）.
    private static func liveKeys() -> Set<String>? {
        let fm = FileManager.default
        let dir = ImportService.importsDirectory()
        guard let items = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let productStoreName = "repaired"
        var productStore: [String: URL] = [:]
        let storeDir = dir.appendingPathComponent(productStoreName, isDirectory: true)
        if fm.fileExists(atPath: storeDir.path) {
            guard let products = try? fm.contentsOfDirectory(at: storeDir,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for p in products where p.pathExtension.lowercased() == "ipa" {
                productStore[p.deletingPathExtension().lastPathComponent] = p
            }
        }
        var keys: Set<String> = []
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // 产物仓库目录本身不是包，跳过.
                if u.lastPathComponent == productStoreName { continue }
                let original = u.appendingPathComponent("original.ipa")
                let product = u.appendingPathComponent("repaired.ipa")
                if fm.fileExists(atPath: product.path) {
                    keys.insert(fm.fileExists(atPath: original.path) ? original.path : product.path)
                } else if fm.fileExists(atPath: original.path) {
                    keys.insert(original.path)
                }
                continue
            }
            guard u.pathExtension.lowercased() == "ipa",
                  u.lastPathComponent != "repaired.ipa" else { continue }
            let flatName = u.deletingPathExtension().lastPathComponent
            keys.insert(productStore[flatName]?.path ?? u.path)
        }
        for (name, product) in productStore {
            let flatOriginal = dir.appendingPathComponent("\(name).ipa")
            if !fm.fileExists(atPath: flatOriginal.path) { keys.insert(product.path) }
        }
        return keys
    }

    private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPackageIcons", isDirectory: true)
    }

    private static func digest(of key: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func cachedFileURL(key: String) -> URL {
        cacheDirectory().appendingPathComponent("\(digest(of: key)).png")
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

        // 1) 按声明名找条目（含常见设备变体后缀），取命中里**最大**的一张。
        //    声明列表通常按小→大排列（如 29/40/57/60），首个命中往往是 29pt 的 @3x：
        //    44pt 缩略图尚可，长按「查看图标 / 提取图标」会糊。这里扫完全部声明名再挑最大的，
        //    既拿到高分辨率，又只认 `CFBundleIcons`（不读 `CFBundleIcons~ipad`，避免挑到 iPad 专属画稿）。
        let suffixes = ["@3x", "@2x", "", "-ipad@2x", "-iphone@3x", "-ipad@1x"]
        var declaredBest: (size: Int, data: Data)?
        for name in declared where !name.isEmpty {
            for suffix in suffixes {
                let target = appPrefix + name + suffix + ".png"
                guard let entry = reader.entries[target],
                      declaredBest == nil || entry.uncompressedSize > declaredBest!.size,
                      let data = try? reader.readEntry(named: target), !data.isEmpty else { continue }
                declaredBest = (entry.uncompressedSize, data)
            }
        }
        if let declaredBest { return declaredBest.data }

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
