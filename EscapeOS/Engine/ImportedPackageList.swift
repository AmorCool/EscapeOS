import Foundation

// 共享转换 · 已导入包清单（用户需求：把已导入的包列出来）
//
// 数据来源是 `Imports/` 目录的**磁盘现状**，不依赖持久化台账（本仓当前没有导入台账落盘）。
// 因此每一行的「状态」都由**磁盘证据**推出，不做无据推断。
//
// 两个块，按**原件是否还在**区分（用户需求 #17/#18/#19/#20）：
//   · 「已导入」= 目录里还有 `original.ipa`（可修补；批量修补只作用于这个块）；
//   · 「已修补」= 原件已被删除、只剩 `repaired.ipa`（修补成功后原件被删，条目落到这里）。
// 判据就是磁盘上 `original.ipa` 在不在，不引入新的持久化状态。
//
// 两种落点形态都要列出（老平铺包不能被落下）：
//   · 老平铺：`Imports/<包名>.ipa`
//   · 新落点：`Imports/<包名>/original.ipa`（+ 同目录 `repaired.ipa`）
//
// 老平铺的 `Imports/repaired.ipa` 落在共享根目录、**无法归因到具体包名**，故不单独成行。
// 「只有 repaired.ipa、没有 original.ipa」的新落点目录 = 已修补块（原件已按 #17 删除）。

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

        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // 形态二（新落点）：`Imports/<包名>/original.ipa` 与 `Imports/<包名>/repaired.ipa`。
                let original = u.appendingPathComponent("original.ipa")
                let product = u.appendingPathComponent("repaired.ipa")
                let hasOriginal = fm.fileExists(atPath: original.path)
                let hasProduct = fm.fileExists(atPath: product.path)
                let name = u.lastPathComponent
                if hasOriginal {
                    // 有原件 ⇒ 已导入块（即便已有产物，仍可重新修补 / 安装）。
                    imported.append(make(name: name, kind: .imported,
                                         original: original,
                                         product: hasProduct ? product : nil,
                                         installedBundleIds: installedBundleIds, fm: fm))
                } else if hasProduct {
                    // 原件已删、只剩产物 ⇒ 已修补块（用户需求 #17）。
                    repaired.append(make(name: name, kind: .repaired,
                                         original: nil, product: product,
                                         installedBundleIds: installedBundleIds, fm: fm))
                }
                // 两者都没有 ⇒ 残留空目录，跳过。
                continue
            }
            // 形态一（老平铺）：`Imports/*.ipa`。排除修补产物 repaired.ipa。
            guard u.pathExtension.lowercased() == "ipa",
                  u.lastPathComponent != "repaired.ipa" else { continue }
            imported.append(make(name: u.deletingPathExtension().lastPathComponent,
                                 kind: .imported, original: u, product: nil,
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

        // bundle id：原件在就用原件，否则用产物（产物是原件的整包副本，Info.plist 一致）。
        let bundleId = meta.flatMap { IPAPackageInspector.inspect(ipaPath: $0.path)?.bundleIdentifier }

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
                               isInstalled: installed,
                               sizeBytes: size, importedAt: when, status: status)
    }
}
