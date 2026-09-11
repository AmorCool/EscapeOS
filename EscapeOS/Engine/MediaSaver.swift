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

    /// 下载图片并解码（长按保存用；比 AsyncImage 更好控质量）
    static func downloadImage(_ urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else { throw Failure(message: "图片地址无效") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let image = UIImage(data: data) else { throw Failure(message: "图片解码失败") }
        return image
    }
}

extension String {
    /// mzstatic 缩略图地址升成高清：`…/100x100bb.jpg` → `…/1024x1024bb.jpg`
    var appStoreHighResImage: String {
        guard range(of: #"\d+x\d+bb"#, options: .regularExpression) != nil else { return self }
        return replacingOccurrences(of: #"\d+x\d+bb"#, with: "1024x1024bb", options: .regularExpression)
    }
}
