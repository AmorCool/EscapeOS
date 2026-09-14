import SwiftUI
import UIKit

// MARK: - 取图（v0.3.404）

/// v0.3.404：预览图的**内存缓存** —— 同一地址只下一次；翻页回来、重开预览都是秒出
///（用户反馈"感觉不能实时刷新"，其实是每翻一页都重下一遍）。
///
/// 只用 `NSCache`（内存，系统吃紧时自己回收）：不做磁盘缓存，避免沙盒里堆一堆过期图。
enum PreviewImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    static func image(for url: String) -> UIImage? { cache.object(forKey: url as NSString) }
    static func store(_ image: UIImage, for url: String) { cache.setObject(image, forKey: url as NSString) }
}

/// v0.3.404：**预览取图的唯一实现** —— 地址候选链 + 内存缓存。
/// 展示（`PreviewImageView`）与「长按保存」都走它，不再各写一条下载路径。
enum PreviewImageLoader {

    /// 「正方形」尺寸变体（`100x100bb` / `1024x1024bb`）—— **只有应用图标**是这种。
    private static let squareSizePattern = #"(\d+)x\1bb"#

    /// **候选地址链**（本项目"点开全屏一片黑"的根因就在这一行上）。
    ///
    /// `String.appStoreHighResImage`（`MediaSaver.swift:69`）是**无差别**地把地址里的
    /// `\d+x\d+bb` 换成 `1024x1024bb` —— 这招只对**正方形**的图标变体成立。
    /// 而截图根本不是正方形：Apple 的 `screenshotUrls` 给的是 `392x696bb`，爱思图床也把
    /// 尺寸写进文件名（`…_540x960bb.jpg` 之类）。换掉之后就是一个**不存在的资源**，
    /// 请求失败 → 全屏什么都没画出来。
    ///
    /// 而缩略图用的是**原址**（`AppStoreDetailView:362`、`I4StoreFreeDetailView:200` 都是
    /// `AsyncImage(url: URL(string: url))`）—— 所以**缩略图看得见、点开全屏一片黑**。
    ///
    /// 因此：只有正方形变体才升高清（图标），而且**高清失败回落原址**；其它地址原样一个候选。
    static func candidateURLs(for raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.range(of: squareSizePattern, options: .regularExpression) != nil else {
            return [trimmed]
        }
        let highRes = trimmed.appStoreHighResImage
        return highRes == trimmed ? [trimmed] : [highRes, trimmed]
    }

    /// 取图：命中缓存直接返回；否则按候选链逐个试，成功即写缓存。
    ///
    /// **每一次尝试都落日志**：v0.3.404 之前这条路径一条日志都没有，出问题只能靠猜。
    /// 日志归在「通用」板块，行首是 `[预览]`，取的是「主机 + 末段路径」——
    /// 尺寸变体（`392x696bb`）就在末段，够定位又不刷屏。
    static func image(for raw: String) async throws -> UIImage {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure(message: "图片地址为空") }
        if let hit = PreviewImageCache.image(for: key) { return hit }

        let candidates = candidateURLs(for: key)
        var lastMessage = "图片地址为空"
        for (index, candidate) in candidates.enumerated() {
            do {
                let image = try await MediaSaver.downloadImage(candidate)
                PreviewImageCache.store(image, for: key)
                log("取图成功（候选 \(index + 1)/\(candidates.count) · \(short(candidate))）")
                return image
            } catch {
                lastMessage = error.localizedDescription
                log("取图失败（候选 \(index + 1)/\(candidates.count) · \(short(candidate))）：\(lastMessage)")
            }
        }
        throw Failure(message: lastMessage)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func short(_ url: String) -> String {
        guard let u = URL(string: url) else { return String(url.suffix(48)) }
        return (u.host ?? "") + "/" + u.lastPathComponent
    }

    private static func log(_ message: String) {
        LoginLogger.shared.log("[预览] \(message)")
    }
}

/// v0.3.404：全屏预览里的**一张图** —— 三种状态都看得见：环形加载 / 图片 / 「加载失败 + 重试」。
///
/// 这里原来是 `AsyncImage`：加载失败只有一枚 40% 白的小图标，没有文案、没有重试、也不写日志，
/// 在纯黑背景上用户看到的就是"点开是黑的、也没转圈"。
struct PreviewImageView: View {
    let url: String

    private enum Phase { case loading, loaded(UIImage), failed }
    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.large).tint(.white)
            case .loaded(let image):
                Image(uiImage: image).resizable().scaledToFit()
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("加载失败")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    Button {
                        retry()
                    } label: {
                        Text("重试")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 撑满一页：不然失败态/转圈会被塞在页面左上角
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        do {
            let image = try await PreviewImageLoader.image(for: url)
            phase = .loaded(image)
        } catch {
            // 具体原因（超时/404/解码失败）只进日志；界面上只给一句短提示，不放长句
            phase = .failed
        }
    }

    /// 重试：同一地址再走一遍（缓存未命中时才真的重发请求）
    private func retry() {
        phase = .loading
        Task { await load() }
    }
}

/// v0.3.399：**全屏图片预览** —— App Store 与爱思源（免登录商店）**共用同一套**。
///
/// 这段原来长在 `AppStoreDetailView.swift` 里、名字叫 `AppStoreScreenshotViewer`（`struct` 本身
/// 不是 private，所以当时只有 App Store 详情页在用）。爱思源这边要用同一个东西时，
/// 那个名字就成了错的 —— 所以搬到本文件并改成中性名，**实现一字未改**，避免在爱思侧再写一套。
///
/// 交互：
/// · 左右翻页（`TabView` + `.page`，底部页码点），进入时定位到点开的那一张；
/// · **长按** 图片 → 二次确认 → 「保存到相册」（失败回落 App 沙盒 `Documents/AppIcons`，见 `MediaSaver`）；
/// · 右上角 ✕ 关闭。
///
/// v0.3.404：**不再用 `AsyncImage`**（失败静默 → 纯黑一片），改走 `PreviewImageView`
/// （环形加载 / 加载失败 + 重试）与 `PreviewImageLoader`（候选地址链 + 内存缓存）；
/// 地址也**不再无差别升高清**（截图的 `392x696bb` 被换成 `1024x1024bb` 就是不存在的资源，
/// 那正是"缩略图能看、点开全黑"的原因，见 `PreviewImageLoader.candidateURLs`）。
struct ImageGalleryViewer: View {
    let urls: [String]
    @State var startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int = 0
    @State private var confirmSave = false
    @State private var pendingURL: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if urls.isEmpty {
                // v0.3.404：空数组以前是**纯黑**（`TabView` 一页都没有 → 什么都不画、也不提示）
                Text("没有可查看的图片")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                TabView(selection: $current) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        PreviewImageView(url: url)
                            .tag(index)
                            .onLongPressGesture(minimumDuration: 0.4) {
                                pendingURL = url
                                confirmSave = true
                            }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
        }
        .confirmationDialog("保存这张图片？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("保存到相册") { savePending() }
            Button("取消", role: .cancel) { pendingURL = nil }
        }
        .toastHost()
        .onAppear { current = min(max(0, startIndex), max(0, urls.count - 1)) }
    }

    private func savePending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        ToastCenter.shared.show("正在保存")
        Task { @MainActor in
            do {
                // v0.3.404：走**同一份取图逻辑** —— 刚看过的图直接命中缓存，不再重下；
                // 也不会再去要那个被"图标高清改写"改坏的地址（旧版存图同样会拿到 404）。
                let image = try await PreviewImageLoader.image(for: url)
                let outcome = try await MediaSaver.save(image, fileName: "screenshot-\(current + 1)")
                switch outcome {
                case .photos: ToastCenter.shared.show("已保存到相册")
                case .files(let name): ToastCenter.shared.show("已存到文件 App：AppIcons/\(name)")
                }
            } catch {
                ToastCenter.shared.show("保存失败：\(error.localizedDescription)")
            }
        }
    }
}

/// 全屏预览「要看第几张」—— `.fullScreenCover(item:)` 需要一个 `Identifiable`。
/// 各页面共用它（截图预览与 v0.3.403 起的单张图标预览都走这里），不再各写一个私有包装。
/// `index` 对图标预览恒为 0（数组里就一张）。
struct ImagePreviewTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

/// v0.3.403：长按菜单里**「查看图标 + 提取图标」这两项的唯一一份内容**。
///
/// 四个调用点（AppleID 商店列表 / AppleID 应用详情 / 爱思源列表 / 爱思源详情）都调它 ——
/// 「查看图标」开 `ImageGalleryViewer`（图标只有一张，塞进去即可），「提取图标」走 `IconExporter`。
/// 别在页面里再抄一份这两行 `Button`，四处菜单长得不一样这个坑刚踩过。
///
/// `viewIcon` 由调用方传入：预览状态是各页自己的 `@State`，这里只负责触发，不持有状态。
///
/// 外面这层 `Group` 不是装饰：菜单项由「返回 `some View` 的函数」给出时，包一层 `Group`
/// 才能被确定地摊平成多条菜单项 —— 本仓库 `FileBrowserView.itemMenu(for:)` 是同样的写法。
///
/// `@MainActor`：**顶层自由函数不会像 `View` 那样被推断成主 actor**，而这里要调
/// `IconExporter`（`@MainActor`）——不标注就是「非隔离上下文调主 actor 方法」。四个调用点
/// 都在 `View` 内，天然在主 actor 上。
@MainActor
@ViewBuilder
func iconMenuItems(iconURL: String?, fileNameBase: String,
                   viewIcon: @escaping @MainActor () -> Void) -> some View {
    Group {
        Button {
            viewIcon()
        } label: {
            Label("查看图标", systemImage: "photo")
        }
        Button {
            IconExporter.save(iconURL: iconURL, fileNameBase: fileNameBase)
        } label: {
            Label("提取图标", systemImage: "square.and.arrow.down")
        }
    }
}

/// v0.3.403：点「查看图标」→ 开**单张**全屏预览（`ImageGalleryViewer`）。
///
/// 地址为空只提示一句、不开空预览；判定与文案四处一致。
/// 图标只有一张，仍然走同一个查看器 —— 于是「长按存图」白得，和截图那条路径行为一致。
/// `@MainActor` 的理由同 `iconMenuItems`（顶层自由函数 + 直接驱动 `ToastCenter`）。
@MainActor
func showIconPreview(_ iconURL: String?,
                     images: Binding<[String]>,
                     target: Binding<ImagePreviewTarget?>) {
    let raw = (iconURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
        ToastCenter.shared.show("没有可查看的图标")
        return
    }
    images.wrappedValue = [raw]
    target.wrappedValue = ImagePreviewTarget(index: 0)
}

/// v0.3.399：**「提取图标」的共用实现** —— 下载图标 → 优先存相册（失败回落 `Documents/AppIcons`）。
///
/// v0.3.399 从 App Store 详情页图标长按的私有实现里抽出来；v0.3.403 起四个页面的
/// 「提取图标」都走这里 —— **同一份实现，不做第二套**。
///
/// `@MainActor`：本类直接驱动 `ToastCenter`（它本身是 `@MainActor` 类）与 UI 状态，
/// 显式标注比依赖「调用点恰好也在主 actor」可靠。异步部分再显式 `Task { @MainActor in }`。
@MainActor
enum IconExporter {

    /// - Parameters:
    ///   - iconURL: 图标地址（空 → 只提示，不做任何事）
    ///   - fileNameBase: 落沙盒时的文件名（不含扩展名）。调用方给 bundleId 或应用名。
    static func save(iconURL: String?, fileNameBase: String) {
        let raw = (iconURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            ToastCenter.shared.show("没有可提取的图标")
            return
        }
        ToastCenter.shared.show("正在提取图标")
        Task { @MainActor in
            do {
                // v0.3.404：图标也走**同一份取图逻辑**（正方形变体升高清、失败回落原址、命中缓存）
                let image = try await PreviewImageLoader.image(for: raw)
                let outcome = try await MediaSaver.save(image, fileName: fileNameBase)
                switch outcome {
                case .photos: ToastCenter.shared.show("图标已存到相册")
                case .files(let name): ToastCenter.shared.show("已存到文件 App：AppIcons/\(name)")
                }
            } catch {
                ToastCenter.shared.show("提取失败：\(error.localizedDescription)")
            }
        }
    }
}
