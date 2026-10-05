import Foundation

// 「从列表移除（不删安装包）」与「彻底删除」的实现（用户需求 #2 / #3）.
//
// 背景：`ImportedPackageList.scanListing` 是**纯磁盘扫描**（见该文件），本仓没有「已导入」台账，
// 因此没有「把某条从列表拿掉、但文件留着」的现成 API。若直接删文件 ⇒ 包真没了；
// 若只在内存里标记 ⇒ 下次扫描（或切页回来）又「复活」。
//
// 方案（用户需求 #2「移除修补项：仅从列表移除，不删安装包」）：把包**移动**到 `Imports/.removed/`。
//   · 移动 ≠ 删除 —— 文件完好，可恢复；
//   · `.removed` 以 `.` 开头 = **隐藏目录**，而两处枚举都用 `options: [.skipsHiddenFiles]`：
//       - `ImportedPackageList.scanListing`  —— `contentsOfDirectory(... options: [.skipsHiddenFiles])`
//       - `ImportService.scanForNewImports`  —— `contentsOfDirectory(... options: [.skipsHiddenFiles])`
//     ⇒ 移入后两处都**看不见**它：列表即刻消失，且「扫描新文件」也不会把它当新包再捞回来。
//
// 恢复：把 `Imports/.removed/` 下的条目移回 `Imports/` 即可（`restoreAll()`）。
// 本组件不删 `.removed/` 里的任何东西 —— 真正的清理留给用户/后续需求，避免误删不可逆。
//
// 「彻底删除」（用户需求 #3「已导入」支持批量移除/删除）走 `delete(_:)`：真删原件落点，
// 顺带清掉老平铺形态按包名归属的产物（若有），避免删完在「已修补」块里「诈尸」。

enum ImportedPackageMover {

    /// 隐藏的「已移除」暂存目录：`Imports/.removed/`（不存在则创建）。
    static func removedDirectory() -> URL {
        let dir = ImportService.importsDirectory()
            .appendingPathComponent(".removed", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 包的**落点根**：新落点 = 包目录（`Imports/<包名>/`），老平铺 = 包文件（`Imports/<包名>.ipa`）。
    ///
    /// 只认 `originalPath`（原件）。已修补块只剩产物、没有原件，不适用「移除原件」⇒ 返回 nil。
    private static func originalRoot(of package: ImportedPackage) -> URL? {
        guard let original = package.originalPath else { return nil }
        let url = URL(fileURLWithPath: original)
        // 新落点的原件固定叫 `original.ipa`，其父目录才是整包落点；老平铺的 path 本身就是落点。
        return url.lastPathComponent == "original.ipa"
            ? url.deletingLastPathComponent()
            : url
    }

    /// 老平铺形态的产物落点：`Imports/repaired/<包名>.ipa`（按包名归属，见 `ImportedPackageList`）。
    private static func flatProductURL(of package: ImportedPackage) -> URL? {
        // 新落点的产物在包目录内（`Imports/<包名>/repaired.ipa`），随包目录一并处理，不在此列。
        guard package.originalPath != nil,
              let original = package.originalPath.map({ URL(fileURLWithPath: $0) }),
              original.lastPathComponent != "original.ipa" else { return nil }
        let name = original.deletingPathExtension().lastPathComponent
        return ImportService.importsDirectory()
            .appendingPathComponent("repaired", isDirectory: true)
            .appendingPathComponent("\(name).ipa")
    }

    /// 在目标目录里取一个**不重名**的落点：重名时追加时间戳，避免覆盖先前已移除的同名包。
    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let stamp = Int(Date().timeIntervalSince1970)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let candidate = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
        return dir.appendingPathComponent(candidate)
    }

    /// 从列表移除（**不删安装包**）：把包落点整体移到 `Imports/.removed/`。
    ///
    /// - Returns: 确实移走返回 `true`；包没有原件 / 落点不存在 / 移动失败返回 `false`（不抛、不静默）。
    @discardableResult
    static func moveToRemoved(_ package: ImportedPackage) -> Bool {
        guard let root = originalRoot(of: package) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }
        let dest = uniqueDestination(in: removedDirectory(), name: root.lastPathComponent)
        do {
            try fm.moveItem(at: root, to: dest)
            return true
        } catch {
            LoginLogger.shared.log("[共享修补] 移除到 .removed 失败：\(error.localizedDescription)",
                                   category: .shareConvert)
            return false
        }
    }

    /// 彻底删除（用户需求 #3「已导入」的移除即删除）：删原件落点，并清掉老平铺产物（若有）。
    ///
    /// - Returns: 原件确实删掉返回 `true`；落点不存在 / 删除失败返回 `false`。
    @discardableResult
    static func delete(_ package: ImportedPackage) -> Bool {
        guard let root = originalRoot(of: package) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }
        do {
            try fm.removeItem(at: root)
        } catch {
            LoginLogger.shared.log("[共享修补] 删除安装包失败：\(error.localizedDescription)",
                                   category: .shareConvert)
            return false
        }
        // 老平铺形态的产物单独落 `Imports/repaired/<包名>.ipa`；不顺手清掉，删完会在「已修补」块里诈尸。
        if let product = flatProductURL(of: package), fm.fileExists(atPath: product.path) {
            try? fm.removeItem(at: product)
        }
        return true
    }

    /// 恢复：把 `Imports/.removed/` 里的暂存项全部移回 `Imports/`。
    ///
    /// 暂存区只做「取走」用途，本组件不主动调用它（恢复入口不在本次需求内），
    /// 保留给后续「已移除」回收站界面 / 误删找回。
    ///
    /// - Returns: 成功移回的条目数。
    @discardableResult
    static func restoreAll() -> Int {
        let fm = FileManager.default
        let dir = removedDirectory()
        let imports = ImportService.importsDirectory()
        guard let items = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var restored = 0
        for item in items {
            let dest = imports.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }  // 不覆盖同名现存包
            do {
                try fm.moveItem(at: item, to: dest)
                restored += 1
            } catch {
                LoginLogger.shared.log("[共享修补] 恢复 \(item.lastPathComponent) 失败：\(error.localizedDescription)",
                                       category: .shareConvert)
            }
        }
        return restored
    }
}
