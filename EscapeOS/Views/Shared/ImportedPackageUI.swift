import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import Darwin   // dlopen / dlclose：诊断私有 CoreUI 取图卡在哪一步（见 assetCatalogFailureStep）

// 共享转换 · 三个二级页（已导入 / 待修补 / 已修补）共用的小件与扫描入口。
//
// 抽出来只为**少写三遍**，不改任何既有行为：
//   · `ImportedPackageScanner`  —— 拿「本机已安装清单 + `Imports/` 磁盘现状」
//   · `ImportedPackageIconView` / `ImportedPackageIconStore` / `ImportedPackageIconExtractor`
//                              —— 从 IPA（zip）里提取真图标：缩略图与长按预览共用同一份
//   · `ImportedPackageMonogram` —— 读不出真图标时的首字母块（回落项）
//   · `PackageChip`             —— 胶囊标签（画法复用 IPADownloadManagerView / ImportView 的 `chip`）
//   · `ImportedPackage.Status` 的 `symbol` / `tint` —— 语义配色一律取 `AppTheme`

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

    /// 状态配色（一律取 `AppTheme` 语义色，自动适配明暗模式，不另造配色）。
    ///
    /// `.repaired` 与 `.installed` 共用 `AppTheme.success` 是**有意为之**，不是笔误：
    /// 这两个状态不会同页共存（「已导入」页的 status 只可能是 awaitingRepair / installed，
    /// 「已修补」页的 status 恒为 repaired），故无需保留「青=已修补 / 绿=已安装」的视觉区分。
    /// 此前借用 `LocusTheme`（硬编码 sRGB、不随明暗模式自适应），浅色底上对比度不足.
    var tint: Color {
        switch self {
        case .awaitingRepair: return AppTheme.pending
        case .repaired:       return AppTheme.success
        case .installed:      return AppTheme.success
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
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ImportedPackageMonogram(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 发丝级描边：浅色底上把图标与背景分开（透明度沿用 `ToastOverlay` 的既有口径）.
        // App 图标画稿自带明暗与高光，故**不加**合成高光，避免与画稿打架.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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
/// 文件名取包 id 的 MD5（跨进程稳定），另拼一个**缓存版本后缀**；命中已存在的文件就直接返回，不再读 zip.
/// Caches 目录可被系统回收，丢了下次重新提取即可.
///
/// 为什么要版本后缀：`iconURL` 命中即返回，若文件名只由包 id 决定，则**提取口径变更后**
/// 旧口径的缓存永远覆盖不掉（v0.3.573 把散装取图从「首个命中」改为「按字节数取最大」、
/// 本轮又从「字节数」改为「真实像素」，都是口径变更）。改一次 `cacheVersion`
/// 即让所有旧缓存文件名不再匹配而自然失效，`pruneStaleIcons` 会顺手清掉.
enum ImportedPackageIconStore {

    /// 缓存版本 —— 变更提取口径（如从「散装 PNG」升级为「优先 Assets.car」）时递增.
    private static let cacheVersion = "icon-v2"

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

    /// 预览专用：**强制**从 IPA 重新提取，绕过磁盘缓存与内存缓存.
    ///
    /// 与 `iconURL(for:)` 的区别：不做「文件存在就直接返回」，每次都是当前提取器的结果 ——
    /// 预览是全屏放大，对清晰度最敏感，不能吃那份「命中即返回、文件名无版本号」的缩略图缓存.
    ///
    /// 落 `temporaryDirectory` 且文件名带 `UUID()`：`PreviewImageLoader.image(for:)` 会先按 URL 字符串
    /// 查内存缓存，固定文件名会让第二次预览命中上一张旧图 —— 带 `UUID` 让每次预览都是全新键.
    /// 临时件由系统回收，不往 `Caches/ImportedPackageIcons` 里堆.
    static func previewIconURL(for package: ImportedPackage) -> String? {
        guard let ipaPath = package.originalPath ?? package.repairedPath,
              !ipaPath.isEmpty else { return nil }
        guard let data = ImportedPackageIconExtractor.iconPNGData(ipaPath: ipaPath) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-preview-\(digest(of: package.id))-\(UUID().uuidString).png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.absoluteString
    }

    /// 清掉「在 `Imports/` 里已找不到对应包」的图标缓存 —— 否则这个目录只增不删.
    ///
    /// 判据与写入用同一把钥匙：缓存文件名就是「包 id（`originalPath ?? repairedPath`）+ 缓存版本」的 MD5.
    /// 时机：`loadIcons()` 开始时（那时已能列出 `Imports/` 现状）.
    /// 不会误删：只要包还在 `Imports/`（原件或产物任一在），其 id 必落在保留集里；
    /// 只有包被移除、或 id 因修补改了落点（`original.ipa` → `repaired.ipa`）而变旧时，
    /// 旧文件才失去对应包而被清掉. 提取口径升级后，旧版本名下的缓存也会在此被清掉.
    /// Caches 目录本就可被系统回收，丢了下次重新提取即可.
    static func pruneStaleIcons() {
        let fm = FileManager.default
        // 读不出 `Imports/` 现状时**不清理** —— 「读不出来 ≠ 确定没有」，否则会把仍有效的图标误删.
        guard let keys = liveKeys() else { return }
        let dir = cacheDirectory()
        guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        let keep = Set(keys.map(cacheFileName(for:)))
        for f in files where f.pathExtension.lowercased() == "png" {
            if !keep.contains(f.lastPathComponent) {
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

    /// 缓存文件名 = `「包 id + 缓存版本」的 MD5` + `.png`。写入（`cachedFileURL`）与清理
    /// （`pruneStaleIcons`）**必须**共用它，否则清理会误删刚写入的文件.
    private static func cacheFileName(for key: String) -> String {
        "\(digest(of: key + "@" + cacheVersion)).png"
    }

    private static func cachedFileURL(key: String) -> URL {
        cacheDirectory().appendingPathComponent(cacheFileName(for: key))
    }
}

/// 从 IPA（zip）里提取应用图标 PNG —— 本仓第一份「从 zip 取图标」的实现。
///
/// 取图顺序：
///   0) **优先** `Payload/<App>.app/Assets.car` —— 现代 IPA 的高清图标只编在这里；
///   1) 散装 PNG：按 `Info.plist` 的图标声明名（`CFBundleIcons.CFBundlePrimaryIcon` /
///      顶层同名键）在 `Payload/<App>.app/` 下试 `@3x / @2x / 无后缀` 及 `~ipad / ~iphone`
///      设备变体，取命中里**像素最大**的一张；
///   2) 兜底：app 包根目录（不含子目录）下像素最大的 PNG。
///
/// 口径与 `LiveContainerDiscovery.loadIconData` 一致（区别只是那边读**已解压目录**、
/// 这里读 **zip 内的条目**）。比较用**真实像素**（ImageIO 解析），不用字节数 ——
/// 同一套图标里字节数只是与像素**相关**，不是可靠度量。
///
/// 读不出（无声明、无散装 PNG、`Assets.car` 也取不到）返回 nil，由调用方回落首字母块 —— 不臆造.
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

        // 0) 优先 Assets.car（现代 IPA 的 1024 图标在这里；散装 PNG 只是老系统兜底的小图）。
        //    取不到返回 nil，**不改变**后面散装 PNG 的任何行为。
        let catalogIcon = assetCatalogIcon(names: names, appPrefix: appPrefix, info: info, reader: reader)

        // 1)+2) 散装 PNG（原逻辑，仅把「比大小」的口径从字节数改成像素）。
        let scatteredIcon = scatteredIcon(names: names, appPrefix: appPrefix,
                                          declared: declared, reader: reader)

        // 两路都拿到就取像素更大的；只有一路拿到就用那一路。car 取到的通常更大，
        // 但若某包的散装 PNG 反而更大（异常包），也不让新逻辑把分辨率**降**下去。
        if let catalogIcon, let scatteredIcon {
            return pixelCount(of: catalogIcon) >= pixelCount(of: scatteredIcon) ? catalogIcon : scatteredIcon
        }
        return catalogIcon ?? scatteredIcon
    }

    /// 从 `Payload/<App>.app/Assets.car` 取最大的一档应用图标并重编码为 PNG。
    /// 取不到（无 car / 私有 CoreUI 不可用 / 解不出图）返回 nil —— 调用方原样回落散装 PNG.
    ///
    /// 三种结果都写 `LoginLogger`（`.shareConvert`）—— 这是**唯一能在真机验证私有 CoreUI 是否生效**
    /// 的抓手：它失败时会静默回落到 120×120，用户仍看到糊图却毫无提示，只有日志能区分。
    private static func assetCatalogIcon(names: [String], appPrefix: String,
                                         info: [String: Any], reader: ZipReader) -> Data? {
        let carName = appPrefix + "Assets.car"
        guard names.contains(carName),
              let carData = try? reader.readEntry(named: carName), !carData.isEmpty else {
            LoginLogger.shared.log("[图标] 无 Assets.car，回落散装 PNG（car=\(carName)）", category: .shareConvert)
            return nil
        }
        // 图标名取声明（`CFBundleIconName` 即 car 内的 rendition 名，通常为 "AppIcon"）。
        let iconName = ((info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String
            ?? info["CFBundleIconName"] as? String
            ?? "AppIcon"
        // `CUICatalog` 需要文件 URL，故先把 car 落到临时文件，用完即删。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("esc-icon-\(UUID().uuidString).car")
        guard (try? carData.write(to: tmp)) != nil else {
            LoginLogger.shared.log("[图标] Assets.car 写临时文件失败，回落散装 PNG（car=\(carName)）", category: .shareConvert)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let png = ESIconPNGDataFromAssetCatalog(tmp, iconName) else {
            LoginLogger.shared.log("[图标] Assets.car 读取失败，回落散装 PNG（car=\(carName)，iconName=\(iconName)）—— 失败步骤：\(assetCatalogFailureStep())",
                                   category: .shareConvert)
            return nil
        }
        let dims = pixelSize(of: png).map { "\($0.width)×\($0.height)" } ?? "尺寸未知"
        LoginLogger.shared.log("[图标] Assets.car 命中 \(dims)（car=\(carName)，iconName=\(iconName)）", category: .shareConvert)
        return png
    }

    /// 私有 CoreUI 取图失败时，从 Swift 侧探出**卡在哪一步**（dlopen / NSClassFromString / 取图或重编码）。
    ///
    /// 前两步与 `AssetCatalogIcon.m` 用的是同一对调用（同一路径的 dlopen、同一个类名），
    /// 结果必然一致；若两步都通过却仍返回 nil，则失败落在 ObjC 内部的 `imageWithName:` 取图
    /// 或 `UIImagePNGRepresentation` 重编码 —— 这两步无法从 Swift 侧单独分辨，故合并成一条.
    private static func assetCatalogFailureStep() -> String {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI",
                                  RTLD_NOW | RTLD_LOCAL) else {
            return "dlopen CoreUI.framework 失败"
        }
        dlclose(handle)
        guard NSClassFromString("CUICatalog") != nil else {
            return "NSClassFromString(\"CUICatalog\") 为 nil"
        }
        return "CUICatalog 可用但 imageWithName 取图 / PNG 重编码未产出"
    }

    /// 散装 PNG 取图：先按声明名（含设备变体后缀）取像素最大的一张，找不到再退到 app 包根目录.
    private static func scatteredIcon(names: [String], appPrefix: String,
                                      declared: [String], reader: ZipReader) -> Data? {
        // 1) 按声明名找条目（含常见设备变体后缀），取命中里**像素最大**的一张。
        //    改动前：按 `entry.uncompressedSize`（压缩前字节数）取最大；改动后：按**真实像素**
        //    （`pixelCount`，ImageIO 解析）取最大。**在现有真实样本上两者结果相同** ——
        //    实测三个 IPA，改动前后都选中同一张（120×120 或 180×180）。故这次改动的价值是
        //    **语义正确**（像素才是尺寸的可信度量，字节数只是与像素相关），**不是**分辨率提升。
        //    只认 `CFBundleIcons`（不读 `CFBundleIcons~ipad`，避免挑到 iPad 专属画稿）。
        //    后缀按 Apple 真实命名：`…@2x~ipad` / `…@3x~iphone`（`~ipad` 在 `@2x` **之后**）。
        //    注意：`@2x~ipad` 虽能命中真实文件，但那个基础名只在 `CFBundleIcons~ipad` 里声明，
        //    而本函数**有意不读**该键 ⇒ 该后缀在真实样本上**实际未被用到**（列出只为命名完整）。
        let suffixes = ["@3x", "@2x", "", "@3x~ipad", "@2x~ipad", "~ipad", "@3x~iphone", "@2x~iphone", "~iphone"]
        var declaredBest: (score: Int, data: Data)?
        for name in declared where !name.isEmpty {
            for suffix in suffixes {
                let target = appPrefix + name + suffix + ".png"
                guard let entry = reader.entries[target],
                      let data = try? reader.readEntry(named: target), !data.isEmpty else { continue }
                let score = scoreOf(data: data, fallbackBytes: entry.uncompressedSize)
                if declaredBest == nil || score > declaredBest!.score {
                    declaredBest = (score, data)
                }
            }
        }
        if let declaredBest { return declaredBest.data }

        // 2) 兜底：app 包根目录（不含子目录）下像素最大的 PNG。
        let pngs = names.filter { name in
            guard name.hasPrefix(appPrefix), name.lowercased().hasSuffix(".png") else { return false }
            return !name.dropFirst(appPrefix.count).contains("/")
        }
        var best: (score: Int, data: Data)?
        for name in pngs {
            guard let entry = reader.entries[name],
                  let data = try? reader.readEntry(named: name), !data.isEmpty else { continue }
            let score = scoreOf(data: data, fallbackBytes: entry.uncompressedSize)
            if best == nil || score > best!.score {
                best = (score, data)
            }
        }
        return best?.data
    }

    /// 排序分：优先用**真实像素**（`w*h`）；解不出像素时才退到字节数（旧口径）—— 仅用于排序，不作尺寸断言.
    private static func scoreOf(data: Data, fallbackBytes: Int) -> Int {
        let pixels = pixelCount(of: data)
        return pixels > 0 ? pixels : fallbackBytes
    }

    /// PNG 的真实像素（`w*h`）。解不出返回 0.
    private static func pixelCount(of data: Data) -> Int {
        guard let size = pixelSize(of: data) else { return 0 }
        return size.width * size.height
    }

    /// PNG 的真实宽高（像素）。用 ImageIO 解析，**不按固定偏移读** —— Apple 的 PNG 是
    /// CgBI 格式（`IHDR` 前多一个 `CgBI` chunk），偏移 16 处的字节不是宽高。解不出返回 nil.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
