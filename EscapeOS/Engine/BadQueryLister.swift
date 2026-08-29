import Foundation

/// 用 `bad_query_list`（fsgetpath inode 扫描）枚举目录。
///
/// 为什么需要它：LiveContainer 访客沙盒下 `FileManager.contentsOfDirectory`
/// 对跨容器路径会被裁剪，返回空列表或残缺列表，实测不可信。凡是「别的 App 容器 /
/// 系统目录」的一级条目枚举都要走这条路 —— 壁纸（PosterBoard 容器）、拨号器主题
/// （电话容器）、文件浏览器（容器根）都依赖它。
///
/// 实现要点：它按 inode 编号从 1 遍历到 `maxInode`，对目标路径做前缀匹配，
/// 因此 `maxInode` 必须覆盖目标文件的 inode 号（设备上通常是几十万到几百万）。
/// 代价是 O(maxInode) 次 fsgetpath 调用，不要在主线程跑。
enum BadQueryLister {

    /// 列出目录下的一级条目完整路径。
    static func paths(at path: String, maxInode: Int64 = 1_000_000) -> [String] {
        path.withCString { cPath in
            guard let raw = bad_query_list(UnsafeMutablePointer(mutating: cPath), maxInode) else {
                return []
            }
            defer { free(raw) }
            return String(cString: raw)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }

    /// 列出目录下的一级条目名（不含路径）。
    static func entryNames(at path: String, maxInode: Int64 = 1_000_000) -> [String] {
        paths(at: path, maxInode: maxInode).map { ($0 as NSString).lastPathComponent }
    }
}
