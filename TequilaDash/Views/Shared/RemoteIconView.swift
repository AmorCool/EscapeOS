import SwiftUI
import Foundation
import UIKit

// 共享组件 · 远程图标（内存缓存 + 在途去重 + 请求超时；加载中 / 失败 / 超时一律静态占位）。
//
// 由两份重复实现收敛而来（均为各自文件内的顶层 private 类型）：
//   · `SignSourceAppListView.SourceAppIconView` —— 54pt；静态占位 + `NSCache` + 在途去重；
//   · `SignSourceListView.SourceIconView`     —— 44pt；**加载中转圈** + 15s 超时兜底。
// 二者功能重叠、行为不一致（一个加载中画占位、一个画 spinner），收敛为本组件后
// **统一为「加载中画静态占位」**。尺寸 / 圆角 / 占位样式由调用方参数化 ⇒ 两页观感保持不变。

/// 图标静态占位的样式 —— 图标名 + 前景色 + 可选底色 + 字号。
///
/// 「长什么样」抽成数据由调用方传入：源内 App 列表是灰底 `app.dashed`；源列表「无地址」是
/// 紫底 `shippingbox.fill`、「加载中 / 失败 / 超时」是裸 `shippingbox.fill`。
/// 组件本身只管「**何时**显示占位」，不关心它长什么样。
struct IconPlaceholderStyle {
    /// SF Symbol 名。
    var icon: String
    /// 图标前景色。
    var tint: Color
    /// 底色；`nil` = 不画底色（透明）。
    var background: Color?
    /// 图标字号（默认 `.title3`，与两页旧实现一致）。
    var font: Font = .title3
}

/// 远程图标组件（共享件）—— 内存缓存 + 在途去重 + 请求超时；
/// **加载中 / 失败 / 超时 / 无地址一律静态占位**，绝不转圈。
///
/// 三条出口（保证一定会终止，不存在「一直转圈」）：
/// · **成功** → 显示真图（`SourceIconLoader` 回调图片）；
/// · **失败** → 静态占位（回调 `nil`）；
/// · **超时** → 静态占位（`SourceIconLoader` 单请求 15s 时限，最迟 15s 回调 `nil`）。
///
/// 并发：`SourceIconLoader` 整类 `@MainActor` 隔离 —— `UIImage` 非 Sendable，图片状态只在主线程
/// 读写；`URLSession` 完成回调只把 `Data`（Sendable）交回主线程，`UIImage` 在主线程才解码，
/// 因此没有「非 Sendable 类型跨隔离传递」的问题（Swift 6 严格并发）。
struct RemoteIconView: View {

    /// 图标地址（空串 / 非法 URL → 直接落 `emptyStyle` 占位，不发请求）。
    let urlString: String?
    /// 边长（两页尺寸不同：源内 App 列表 54、源列表 44）。
    let side: CGFloat
    /// 圆角（源内 App 列表 12、源列表 10）。
    let cornerRadius: CGFloat
    /// 加载中 / 失败 / 超时的静态占位样式。
    let placeholderStyle: IconPlaceholderStyle
    /// 无地址（空串 / 非法 URL）时的静态占位样式；`nil` ⇒ 与 `placeholderStyle` 相同。
    var emptyStyle: IconPlaceholderStyle?
    /// 真图加载成功后，是否仍把静态占位留在真图**之下**。
    ///
    /// · `true`（源内 App 列表）：占位当「底卡」常在 —— 旧实现 `ZStack { 占位; 真图 }` 即如此，
    ///   图标透明区域会透出灰底，逐像素保持一致；
    /// · `false`（源列表）：有真图即**不画**占位 —— 旧实现 `AsyncImage` 直接替换内容、无底，保持不变。
    var keepsPlaceholderBehindImage: Bool = true

    @State private var image: UIImage?

    /// 归一化后的可用地址（去首尾空白 + 非空 + 可解析为 URL）；不满足 ⇒ `nil`（走 `emptyStyle`）。
    private var resolvedKey: String? {
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = trimmed, !key.isEmpty, URL(string: key) != nil else { return nil }
        return key
    }

    /// 当前应显示的占位样式（无地址 → `emptyStyle`；否则 → `placeholderStyle`）。
    private var activeStyle: IconPlaceholderStyle {
        resolvedKey == nil ? (emptyStyle ?? placeholderStyle) : placeholderStyle
    }

    var body: some View {
        ZStack {
            // 加载中 / 失败 / 超时都停在这一层；有真图时按 `keepsPlaceholderBehindImage` 决定是否保留底卡。
            if image == nil || keepsPlaceholderBehindImage {
                placeholder(activeStyle)
            }
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // `id:` 绑定地址：行被复用成另一条时重跑，不会残留上一张图。
        .task(id: urlString) {
            guard let key = resolvedKey else { image = nil; return }
            // 命中缓存即时落地；未命中先清空（回到静态占位，不显示上一张图），再异步替换。
            image = SourceIconLoader.shared.cached(key)
            let loaded = await SourceIconLoader.shared.image(for: key)
            if !Task.isCancelled { image = loaded }
        }
    }

    /// 静态占位渲染（可选底色 + 图标）—— 加载中 / 失败 / 超时 / 无地址共用同一渲染路径。
    private func placeholder(_ style: IconPlaceholderStyle) -> some View {
        ZStack {
            if let background = style.background { background }
            Image(systemName: style.icon)
                .font(style.font)
                .foregroundStyle(style.tint)
        }
    }
}

// MARK: - 图标加载器（内存缓存 + 在途去重 + 请求超时）

/// 图标加载器 —— 内存缓存 + 在途去重 + 请求超时。
///
/// 对标全能签 `-[AISSoftwareSourceStore imageForRemoteURLString:completion:]` @`0x100380440`
/// （对照报告 §2.2）：命中缓存即时回调；未命中才发起下载；**同一地址并发只下一次**
/// （两行引用同一张图时不会重复下载）。
///
/// 并发：整类 `@MainActor` 隔离 —— `UIImage` 非 Sendable，所有图片状态只在主线程读写；
/// `URLSession` 的完成回调只把 `Data`（Sendable）交回主线程，`UIImage` 在主线程才解码，
/// 因此没有「非 Sendable 类型跨隔离传递」的问题（Swift 6 严格并发）。
@MainActor
private final class SourceIconLoader {

    static let shared = SourceIconLoader()

    /// 单次请求时限（秒）。取 **15** —— 与 `SignSourceClient`（`timeoutIntervalForRequest = 15`）
    /// 同一口径。**必须有上限**：全能签是 45s/候选，我们不做多候选，取更短的 15s 保证
    /// 「最迟 15s 一定落静态占位」。
    private static let timeout: TimeInterval = 15

    /// 已解码图片的内存缓存（key = 图标地址）。`NSCache` 线程安全、系统吃紧时自动回收。
    private let images = NSCache<NSString, UIImage>()
    /// 在途请求的等待者（key = 图标地址）：同址并发只下一次，其余挂起等同一结果。
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    private let session: URLSession

    private init() {
        // `.default` 复用 `URLCache.shared`：源图标响应带 `Cache-Control: max-age` ⇒ 首次落地后
        // 跨启动仍可命中（等价于一份磁盘级缓存）；本类再加一层「已解码图片」的内存缓存。
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout * 2
        session = URLSession(configuration: config)
        images.countLimit = 200
    }

    /// 同步查内存缓存（命中即无需异步；视图首帧用它避免旧图残留）。
    func cached(_ url: String) -> UIImage? { images.object(forKey: url as NSString) }

    /// 取图：命中缓存即时返回；否则下载（同址去重）；失败 / 超时返回 `nil`。
    func image(for url: String) async -> UIImage? {
        if let hit = images.object(forKey: url as NSString) { return hit }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            enqueue(url) { continuation.resume(returning: $0) }
        }
    }

    /// 入队一个请求；同址已有在途请求则只登记等待者（不重复下载）。
    private func enqueue(_ url: String, _ completion: @escaping (UIImage?) -> Void) {
        if waiters[url] != nil {
            waiters[url]?.append(completion)
            return
        }
        waiters[url] = [completion]
        guard let target = URL(string: url) else { finish(url, nil); return }
        session.dataTask(with: target) { [weak self] data, _, _ in
            // 只把 `Data` 交回主线程，`UIImage` 在主线程解码 —— 见类注释的并发说明。
            Task { @MainActor in
                self?.finish(url, data.flatMap { UIImage(data: $0) })
            }
        }.resume()
    }

    /// 收口：写缓存（成功时）+ 唤醒全部等待者。`waiters` 至多被唤醒一次，保证 continuation 只 resume 一次。
    private func finish(_ url: String, _ image: UIImage?) {
        if let image { images.setObject(image, forKey: url as NSString) }
        for waiter in waiters.removeValue(forKey: url) ?? [] { waiter(image) }
    }
}
