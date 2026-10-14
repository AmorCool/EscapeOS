import Foundation

// 共享转换 · 已导入包清单（用户需求：把已导入的包列出来）
//
// 数据来源是 `Imports/` 目录的**磁盘现状**，不依赖持久化台账（本仓当前没有导入台账落盘）。
// 因此每一行的「状态」都由**磁盘证据**推出，不做无据推断。
//
// 两个块，按**有没有修补产物**区分（用户需求 #5/#17/#18/#19/#20）：
//   · 「已导入」= 只有原件 `original.ipa`、**还没有** `repaired.ipa`（可修补；批量修补只作用于这个块）；
//   · 「已修补」= **存在** `repaired.ipa`（不论原件是否还在 —— 修补成功即归此块）。
//
// 为什么判据是「产物存在」而不是「原件已删」：
//   原件只在**安装成功**后才删。若按「原件已删」归块，则「修补成功但用户取消安装」
//   的包会一直卡在「已导入」，而「已修补」块才是安装/导出入口 ⇒ 用户会以为包丢了。
//   判据与「是否安装」解绑后，修补与安装不再互相绑架。
//
// 两种落点形态都要列出（老平铺包不能被落下）：
//   · 老平铺：`Imports/<包名>.ipa`（产物落 `Imports/repaired/<包名>.ipa`，按包名归属）
//   · 新落点：`Imports/<包名>/original.ipa`（+ 同目录 `repaired.ipa`）

/// 一个已导入包（从 `Imports/` 磁盘现状推导，不依赖持久化台账）。
struct ImportedPackage: Identifiable, Hashable, Sendable {

    enum Status: Hashable, Sendable {
        case awaitingRepair   // 待修补
        case repaired         // 已修补
        case installed        // 已安装

        /// 界面文案（句末用英文 `.`）
        var text: String {
            switch self {
            case .awaitingRepair: return "待修补"
            case .repaired:       return "已修补"
            case .installed:      return "已安装"
            }
        }
    }

    /// 归属的块：有原件 = 已导入；只剩产物 = 已修补。
    enum Kind: Hashable, Sendable {
        case imported
        case repaired
    }

    let id: String            // 唯一键：有原件取原件路径，否则取产物路径
    let name: String          // 展示名（新落点 = 目录名；老平铺 = 去扩展名）
    let kind: Kind
    let originalPath: String? // 原件路径（进入修补流程用；已修补块为 nil）
    let repairedPath: String? // 修补产物路径（有产物时非 nil）
    let bundleId: String?     // 包内应用标识（已修补块安装时要用）
    let version: String?      // 包内应用版本（CFBundleVersion / 短版本）；读不出为 nil，界面不臆造
    /// 本机是否已装同 bundleId 的应用。`nil` = 查不到清单（未配对 / 隧道不可用），不做断言。
    let isInstalled: Bool?
    let sizeBytes: Int64
    let importedAt: Date      // 原件落盘时间（创建时间，取不到退修改时间）
    let status: Status

    var sizeText: String { IPADownloadLibrary.sizeText(sizeBytes) }
}

enum ImportedPackageList {

    /// 扫描结果：两个块分开返回。
    struct Listing: Sendable {
        var imported: [ImportedPackage]
        var repaired: [ImportedPackage]
        var isEmpty: Bool { imported.isEmpty && repaired.isEmpty }
    }

    /// 扫描 `Imports/`，按「导入时间」倒序返回两个块。
    ///
    /// - Parameter installedBundleIds: 本机已安装应用的 bundleId 集合。
    ///   传 `nil` 表示**查不到**（未配对 / 隧道不可用）—— 此时**不做**「已安装」判定，
    ///   `isInstalled` 保持 `nil`，绝不凭空断言已安装。
    static func scanListing(installedBundleIds: Set<String>?) -> Listing {
        let fm = FileManager.default
        let dir = ImportService.importsDirectory()
        let items = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var imported: [ImportedPackage] = []
        var repaired: [ImportedPackage] = []

        // 老平铺包产物仓库：`Imports/repaired/<包名>.ipa`（按包名归属，避免多个老平铺包互相覆盖）。
        let productStoreName = "repaired"
        var productStore: [String: URL] = [:]   // 包名（去扩展名）-> 产物 URL
        let storeDir = dir.appendingPathComponent(productStoreName, isDirectory: true)
        if let products = try? fm.contentsOfDirectory(at: storeDir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for p in products where p.pathExtension.lowercased() == "ipa" {
                productStore[p.deletingPathExtension().lastPathComponent] = p
            }
        }

        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // 产物仓库目录本身不是包，跳过（其内容按包名归属到老平铺包，见下方）。
                if u.lastPathComponent == productStoreName { continue }
                // 形态二（新落点）：`Imports/<包名>/original.ipa` 与 `Imports/<包名>/repaired.ipa`。
                let original = u.appendingPathComponent("original.ipa")
                let product = u.appendingPathComponent("repaired.ipa")
                let hasOriginal = fm.fileExists(atPath: original.path)
                let hasProduct = fm.fileExists(atPath: product.path)
                let name = u.lastPathComponent
                if hasProduct {
                    // **有产物 ⇒ 已修补块**（不论原件在不在）。
                    // 用户需求 #5：修补成功就该进「已修补」，不能被「是否安装成功」绑架 ——
                    // 旧判据是「原件已删」，而原件只在安装成功后才删，
                    // 于是「修补成功但取消安装」的包会一直卡在「已导入」，用户以为丢了。
                    repaired.append(make(name: name, kind: .repaired,
                                         original: hasOriginal ? original : nil,
                                         product: product,
                                         installedBundleIds: installedBundleIds, fm: fm))
                } else if hasOriginal {
                    // 无产物、有原件 ⇒ 已导入块（待修补）。
                    imported.append(make(name: name, kind: .imported,
                                         original: original, product: nil,
                                         installedBundleIds: installedBundleIds, fm: fm))
                }
                // 两者都没有 ⇒ 残留空目录，跳过。
                continue
            }
            // 形态一（老平铺）：`Imports/*.ipa`。排除修补产物 repaired.ipa。
            guard u.pathExtension.lowercased() == "ipa",
                  u.lastPathComponent != "repaired.ipa" else { continue }
            let flatName = u.deletingPathExtension().lastPathComponent
            // 老平铺产物落 `Imports/repaired/<包名>.ipa`，按包名归属到这一行。
            // 与形态二同口径：**有产物就归「已修补」**（不论原件是否还在）。
            if let product = productStore[flatName] {
                repaired.append(make(name: flatName, kind: .repaired, original: nil,
                                     product: product,
                                     installedBundleIds: installedBundleIds, fm: fm))
            } else {
                imported.append(make(name: flatName, kind: .imported, original: u,
                                     product: nil,
                                     installedBundleIds: installedBundleIds, fm: fm))
            }
        }

        // 产物仓库里那些**原件已不存在**的包：一并归「已修补」（原件还在的已在上面按行归属）。
        for (name, product) in productStore {
            let flatOriginal = dir.appendingPathComponent("\(name).ipa")
            if fm.fileExists(atPath: flatOriginal.path) { continue }
            repaired.append(make(name: name, kind: .repaired, original: nil, product: product,
                                 installedBundleIds: installedBundleIds, fm: fm))
        }

        return Listing(imported: imported.sorted { $0.importedAt > $1.importedAt },
                       repaired: repaired.sorted { $0.importedAt > $1.importedAt })
    }

    /// 只取「已导入」块的便捷入口（保留旧调用形态）。
    static func scan(installedBundleIds: Set<String>?) -> [ImportedPackage] {
        scanListing(installedBundleIds: installedBundleIds).imported
    }

    /// 组装一行；状态按磁盘证据判定。
    private static func make(name: String, kind: ImportedPackage.Kind,
                             original: URL?, product: URL?,
                             installedBundleIds: Set<String>?,
                             fm: FileManager) -> ImportedPackage {
        // 元数据优先取原件；已修补块没有原件，退到产物。
        let meta = original ?? product
        let vals = meta.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        }
        let size = Int64(vals?.fileSize ?? 0)
        let when = vals?.creationDate ?? vals?.contentModificationDate ?? .distantPast

        // bundle id / 版本：原件在就用原件，否则用产物（产物是原件的整包副本，Info.plist 一致）。
        // 只 inspect 一次，bundleId 与 version 同源取，避免重复读 ZIP 中央目录。
        let inspected = meta.flatMap { IPAPackageInspector.inspect(ipaPath: $0.path) }
        let bundleId = inspected?.bundleIdentifier
        let version = inspected?.bundleVersion

        // 已安装证据：能查到清单（非 nil）且 bundleId 命中。查不到时保持 nil，不做断言。
        let installed: Bool? = {
            guard let installedBundleIds, let bid = bundleId else { return nil }
            return installedBundleIds.contains(bid)
        }()

        let status: ImportedPackage.Status
        switch kind {
        case .repaired:
            // 已修补块：原件已删，状态就是「已修补 / 已安装」。
            status = (installed == true) ? .installed : .repaired
        case .imported:
            status = (installed == true) ? .installed : (product != nil ? .repaired : .awaitingRepair)
        }

        let key = original?.path ?? product?.path ?? name
        return ImportedPackage(id: key, name: name, kind: kind,
                               originalPath: original?.path,
                               repairedPath: product?.path,
                               bundleId: bundleId,
                               version: version,
                               isInstalled: installed,
                               sizeBytes: size, importedAt: when, status: status)
    }
}
