import SwiftUI
import UIKit

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
/// 地址统一先过 `appStoreHighResImage`（把 mzstatic 的 `…/100x100bb.jpg` 升成 `…/1024x1024bb.jpg`）；
/// 非 mzstatic 的地址（爱思源的图床）不匹配那个正则，**原样返回**，所以同一条路径对两边都成立。
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
            TabView(selection: $current) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: URL(string: url.appStoreHighResImage)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                        case .failure:
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                        default:
                            ProgressView().tint(.white)
                        }
                    }
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
        Task {
            do {
                let image = try await MediaSaver.downloadImage(url.appStoreHighResImage)
                let outcome = try await MediaSaver.save(image, fileName: "screenshot-\(current + 1)")
                await MainActor.run {
                    switch outcome {
                    case .photos: ToastCenter.shared.show("已保存到相册")
                    case .files(let name): ToastCenter.shared.show("已存到文件 App：AppIcons/\(name)")
                    }
                }
            } catch {
                await MainActor.run { ToastCenter.shared.show("保存失败：\(error.localizedDescription)") }
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
                let image = try await MediaSaver.downloadImage(raw.appStoreHighResImage)
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
