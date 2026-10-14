import Foundation
import Photos
import UIKit

/// 图片落盘：优先存系统相册，失败（无权限 / LiveContainer 受限）则存到 App 的 `Documents/AppIcons`。
///
/// 需要 Info.plist 的 `NSPhotoLibraryAddUsageDescription`。
enum MediaSaver {

    enum Outcome {
        case photos
        case files(String)      // 落到沙盒里的相对路径
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 保存一张图片
    static func save(_ image: UIImage, fileName: String) async throws -> Outcome {
        if await saveToPhotos(image) { return .photos }
        return .files(try saveToDocuments(image, fileName: fileName).lastPathComponent)
    }

    // MARK: - 相册

    private static func saveToPhotos(_ image: UIImage) async -> Bool {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, _ in cont.resume(returning: ok) })
        }
    }

    // MARK: - 沙盒

    @discardableResult
    static func saveToDocuments(_ image: UIImage, fileName: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = fileName.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(safe.lowercased().hasSuffix(".png") ? safe : safe + ".png")
        guard let data = image.pngData() else { throw Failure(message: "图片编码失败") }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 下载

    /// 下载图片并解码（长按保存用；比 AsyncImage 更好控质量）。
    ///
    /// v0.3.573：`file://`（如从 IPA 提取的图标，`ImportedPackageIconStore` 给的地址）**走本地文件读取**，
    /// 不走 `URLSession`。理由**不是**「`URLSession` 不支持 `file` scheme」（Apple 文档写明原生支持
    /// `data` / `file` / `ftp` / `http` / `https`），而是：**本地文件用本地 API 更直接**，
    /// 且**与缩略图统一成一条路** —— `ImportedPackageIconView.load()`（`ImportedPackageUI.swift`）
    /// 读的就是 `UIImage(contentsOfFile:)`。同一个文件不再「缩略图走本地、查看走 URLSession」两条路，
    /// 也不再依赖「`URLSession` 在真机上如何处理 `file` scheme」这个本仓无法真机验证的假设。
    ///
    /// `http(s)://` 一字不动，仍走 `URLSession`（商店网络图、截图预览都在这条路上）。
    ///
    /// 这是「查看图标 / 提取图标」两条菜单的**唯一汇合点**：二者都经
    /// `PreviewImageLoader.image(for:)` → 本方法，别处不再有第二个 URL 取图实现。
    static func downloadImage(_ urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else { throw Failure(message: "图片地址无效") }
        if url.isFileURL {
            guard let image = UIImage(contentsOfFile: url.path) else {
                throw Failure(message: "图片解码失败")
            }
            return image
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let image = UIImage(data: data) else { throw Failure(message: "图片解码失败") }
        return image
    }
}

// MARK: - 应用图标 / 截图的高清地址

// v0.3.406：这里原来有一个 `extension String { var appStoreHighResImage }`，
// 它**无差别**把地址里的 `\d+x\d+bb` 换成 `1024x1024bb` —— 只对正方形（图标）成立；
// 截图不是正方形（Apple 给 `392x696bb`、爱思图床 `…_540x960bb.jpg`），换出来是**不存在的资源**，
// 请求必失败 → 「缩略图看得见、点开全屏一片黑」。（删除前已确认全仓零调用点。）
//
// 高清改写现在**只有一份实现**：`PreviewImageLoader.candidateURLs`
//（`Views/ImagePreviewSupport.swift`）—— **按原比例**放大（宽 1024、高按比例），
// 并且**保留原址作第二候选**、失败自动回落。展示 / 长按保存 / 提取图标都走它。
//
// 注意： 不要再在这里写第二个"无差别升到 1024x1024"的版本 —— 那正是黑屏的成因。
