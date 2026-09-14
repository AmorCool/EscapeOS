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
/// 三个调用点（App Store 详情页 / App Store 榜单行 / 爱思源详情页）共用它，不再各写一个私有包装。
struct ImagePreviewTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

/// v0.3.399：**「提取图标」的共用实现** —— 下载图标 → 优先存相册（失败回落 `Documents/AppIcons`）。
///
/// 从 `AppStoreDetailView.extractIcon()` 抽出来（原来只有 App Store 详情页的图标长按能用），
/// 爱思源的行长按菜单现在也走这里 —— **同一份实现，不做第二套**。
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
