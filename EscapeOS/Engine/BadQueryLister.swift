import Foundation

/// 用 `bad_query_list`（fsgetpath inode 扫描）枚举目录.
///
/// 为什么需要它：LiveContainer 访客沙盒下 `FileManager.contentsOfDirectory`
/// 对跨容器路径会被裁剪，返回空列表或残缺列表，实测不可信.凡是「别的 App 容器 /
/// 系统目录」的一级条目枚举都要走这条路 —— 壁纸（PosterBoard 容器）、拨号器主题
/// （电话容器）、文件浏览器（容器根）都依赖它.
///
/// 实现要点：它按 inode 编号从 1 遍历到 `maxInode`，对目标路径做前缀匹配，
/// 因此 `maxInode` 必须覆盖目标文件的 inode 号（设备上通常是几十万到几百万）.
/// 代价是 O(maxInode) 次 fsgetpath 调用，不要在主线程跑.
///
/// **v0.3.412**：把 `bad_query_list` 调用收口在 `ExploitPicker.run` 里——
/// 用户在「更多 → 漏洞利用」里关掉 `.badQueryList` 时，本类的所有入口直接返回空集，
/// 由调用方决定怎么降级显示. `run` 内部按"随机顺序 + 失败切下一个"的策略遍历
/// 已勾选的漏洞利用，目前只有 `badQueryList` 一种，行为与改造前完全一致.
enum BadQueryLister {

    /// 列出目录下的一级条目完整路径.
    /// - Returns: `nil` 表示「没有可用的漏洞利用」或本次调用失败（与「目录真为空」
    ///   区分不开，由调用方按上下文判断）; 非 nil 数组（可能为空）= 实际结果.
    static func paths(at path: String, maxInode: Int64 = 1_000_000) -> [String]? {
        ExploitPicker.run { kind in
            switch kind {
            case .badQueryList:
                return _pathsViaBadQuery(at: path, maxInode: maxInode)
            }
        }
    }

    /// 列出目录下的一级条目名（不含路径）.
    static func entryNames(at path: String, maxInode: Int64 = 1_000_000) -> [String]? {
        paths(at: path, maxInode: maxInode).map { $0.map { ($0 as NSString).lastPathComponent } }
    }

    // MARK: - 私有：每种漏洞利用的具体实现

    /// `bad_query_list` 系统调用的实际封装.
    private static func _pathsViaBadQuery(at path: String, maxInode: Int64) -> [String]? {
        path.withCString { cPath in
            guard let raw = bad_query_list(UnsafeMutablePointer(mutating: cPath), maxInode) else {
                return nil
            }
            defer { free(raw) }
            return String(cString: raw)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }
}
