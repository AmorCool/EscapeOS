import Foundation
import UIKit

/// 锁屏密码键盘主题（`.passthm`）—— 移植自 Mak5er/AirCard 的功能.
///
/// ## `.passthm` 是什么
/// 一个 zip，里面是一堆按键 PNG. 文件名编码了「语言 / 数字 / 副文本 / 颜色 / 粗细」：
/// `en-1---white.png`、`ru-5-J K L--white-bold.png`（副文本就是按键上那行小字）.
///
/// ## 落到设备哪里（AirCard 同款）
/// `/var/mobile/Library/Caches/TelephonyUI-8` / `-9` / `-10`，系统按 iOS 版本用其中一个.
///
/// ## 前提（真机实测，写清楚免得白试）
/// 那三个目录**必须已经存在** —— airlift 在 Media 之外**建不了目录**
/// （沙盒允许建普通文件、不允许建目录）. 目录不存在时批量写会报 `payload_* 已被搬走 = 0/N`.
///
/// ## 素材来源
/// 命名约定与解析规则照 AirCard 的 `aircard_backend.py:265-380`，逻辑用 Swift 重写.
enum PasscodeTheme {

    /// 一个按键图.
    struct Key: Identifiable {
        let id = UUID()
        /// 原始文件名（写回设备时用它）
        let fileName: String
        /// 键位（`0`~`9` / `*` / `#`）；解析不出来就是 nil
        let digit: String?
        /// 按键上那行小字
        let subtext: String
        let data: Data
    }

    struct Theme {
        let name: String
        let keys: [Key]
        /// 从路径里猜出来的 TelephonyUI 版本（8 / 9 / 10）；猜不出给 10
        let guessedVersion: Int
    }

    enum ThemeError: LocalizedError {
        case badArchive(String)
        case noImages

        var errorDescription: String? {
            switch self {
            case .badArchive(let m): return "主题包解析失败：\(m)"
            case .noImages: return "这个主题包里没有图片"
            }
        }
    }

    /// 设备上三个候选目录（按新到旧）.
    static let deviceDirs = [
        "/var/mobile/Library/Caches/TelephonyUI-10",
        "/var/mobile/Library/Caches/TelephonyUI-9",
        "/var/mobile/Library/Caches/TelephonyUI-8",
    ]

    /// 12 个键位（iOS 键盘顺序：1-9 然后 * 0 #）.
    static let keypadOrder = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    /// 英文键盘默认副文本.
    static let defaultSubtexts = ["", "ABC", "DEF", "GHI", "JKL", "MNO",
                                  "PQRS", "TUV", "WXYZ", "", "", ""]

    // MARK: - 读

    /// 解析一个 `.passthm`（zip）.
    static func load(url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        let entries: [ZipEntry]
        do {
            entries = try ZipContainer.open(container: data)
        } catch {
            throw ThemeError.badArchive(error.localizedDescription)
        }

        var keys: [Key] = []
        var version = 10
        for entry in entries {
            let path = entry.info.name
            guard !path.hasSuffix("/") else { continue }
            let lower = path.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"),
                  let bytes = entry.data, !bytes.isEmpty else { continue }
            let fileName = (path as NSString).lastPathComponent
            keys.append(Key(fileName: fileName,
                            digit: digit(from: fileName),
                            subtext: subtext(from: fileName),
                            data: bytes))
            if let v = telephonyVersion(in: path) { version = v }
        }
        guard !keys.isEmpty else { throw ThemeError.noImages }
        return Theme(name: url.deletingPathExtension().lastPathComponent,
                     keys: keys.sorted { lhs, rhs in
                         let l = keypadOrder.firstIndex(of: lhs.digit ?? "") ?? 99
                         let r = keypadOrder.firstIndex(of: rhs.digit ?? "") ?? 99
                         return l == r ? lhs.fileName < rhs.fileName : l < r
                     },
                     guessedVersion: version)
    }

    /// 文件名 → 键位. 约定 `{lang}-{digit}-{subtext}--{color}{-bold}.png`.
    static func digit(from fileName: String) -> String? {
        let parts = stem(fileName).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// 文件名 → 副文本（第 3 段）.
    static func subtext(from fileName: String) -> String {
        let parts = stem(fileName).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return "" }
        return parts[2].trimmingCharacters(in: .whitespaces)
    }

    private static func stem(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    private static func telephonyVersion(in path: String) -> Int? {
        for v in [8, 9, 10] where path.contains("TelephonyUI-\(v)") { return v }
        return nil
    }

    // MARK: - 写（导出成 .passthm）

    /// 把主题导出成一个 `.passthm`（zip）.
    static func export(_ theme: Theme, to url: URL) throws {
        let writer = ZipWriter()
        try writer.begin(at: url)
        for key in theme.keys {
            try writer.addFile(name: key.fileName, data: key.data)
        }
        try writer.finish()
    }

    // MARK: - 切片（从一张壁纸切出 12 个键）

    /// 把一张竖版海报**等分切成 12 块**，按 `1-9 * 0 #` 的顺序命名.
    ///
    /// 这是 AirCard「Seamless Poster Slicing」的等价实现：整图切 4 列 x 3 行，
    /// 每块就是一个按键. 输出文件名用同一套约定，所以能直接拿去「应用到设备」.
    static func slice(poster: UIImage,
                      language: String = "en",
                      subtexts: [String] = defaultSubtexts) -> [Key] {
        let cols = 4, rows = 3
        guard let cg = poster.cgImage else { return [] }
        let tileWidth = CGFloat(cg.width) / CGFloat(cols)
        let tileHeight = CGFloat(cg.height) / CGFloat(rows)

        var keys: [Key] = []
        for (index, digit) in keypadOrder.enumerated() {
            let column = index % cols
            let row = index / cols
            let rect = CGRect(x: CGFloat(column) * tileWidth,
                              y: CGFloat(row) * tileHeight,
                              width: tileWidth,
                              height: tileHeight)
            guard let tile = cg.cropping(to: rect),
                  let png = UIImage(cgImage: tile).pngData() else { continue }
            let sub = index < subtexts.count ? subtexts[index] : ""
            let name = sub.isEmpty
                ? "\(language)-\(digit)---white.png"
                : "\(language)-\(digit)-\(sub)--white.png"
            keys.append(Key(fileName: name, digit: digit, subtext: sub, data: png))
        }
        return keys
    }
}
