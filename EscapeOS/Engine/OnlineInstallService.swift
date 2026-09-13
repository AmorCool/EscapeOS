import Foundation

/// v0.3.378：在线安装（OTA）—— 把远端安装包直接推到设备安装，不落本地下载。
///
/// ⚠️ **当前只有接口，没有实现**：机制仍在逆向中（NB 助手 / Syllabic 的在线安装通道）。
/// 本类型的调用**一律返回 `notImplemented`**，UI 按这个真实返回值原样提示，
/// 不伪造成功路径、不做假进度。拿到机制结论后只改这里的方法体即可。
enum OnlineInstallService {

    /// 是否已接入真实实现。
    /// UI 用它给「在线安装」行加「未接入」标记；接真实现后置 `true`，标记自动消失。
    static let isImplemented = false

    enum OnlineInstallError: Error, LocalizedError {
        case notImplemented

        var errorDescription: String? {
            switch self {
            case .notImplemented: return "在线安装尚未接入"
            }
        }
    }

    /// 在线安装入口。
    ///
    /// - Parameters:
    ///   - ipaURL: 远端安装包地址（台账里没有来源直链时传 `nil`）
    ///   - bundleId: 目标应用标识
    ///   - completion: 主线程回调；当前恒为 `.failure(.notImplemented)`
    static func install(ipaURL: URL?,
                        bundleId: String?,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(.failure(OnlineInstallError.notImplemented))
        }
    }
}
