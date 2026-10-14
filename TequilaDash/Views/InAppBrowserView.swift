import SwiftUI
import WebKit

/// App 内置网页浏览器（WKWebView）—— **不再静默跳转到外部 App / Safari**。
///
/// 顶部栏：标题 + 「用系统浏览器打开」（右上角 `safari`）+ 「分享链接」（`UIActivityViewController`）+ 关闭。
/// 自带加载进度条与返回上一页。
struct InAppBrowserView: View {

    let title: String
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()
    @State private var shareTarget: LinkShareTarget?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebViewContainer(model: model, url: url)
                    .ignoresSafeArea(edges: .bottom)
                if model.progress < 1 {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
                // 「用系统浏览器打开」—— 排在分享之前，分享图标保持在最右侧原位（与截图一致）。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openInSystemBrowser()
                    } label: {
                        Image(systemName: "safari")
                    }
                    .disabled(systemBrowserURL == nil)
                    .accessibilityLabel("用系统浏览器打开")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareTarget = LinkShareTarget(title: model.pageTitle ?? title, url: model.currentURL ?? url)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享链接")
                }
            }
            .sheet(item: $shareTarget) { ShareSheet(items: $0.items) }
        }
    }

    /// 交给系统浏览器打开的地址（右上角 `safari` 按钮）。
    ///
    /// · 取**导航后**的当前页地址（`WKWebView.url`，由 `BrowserModel.currentURL` 承接）；尚未加载完
    ///   （`currentURL == nil`）时退回初始 `url`。
    /// · 只认 http(s)：`itms-services://`（在线安装兜底）与 `nsk-sign://` 深链这类**非 http(s)**
    ///   地址，交给系统浏览器打开没有意义（深链的「跳转」归导航策略 `decidePolicyFor` 处理），
    ///   故此时返回 `nil` ⇒ 按钮置灰不可点。
    private var systemBrowserURL: URL? {
        let candidate = model.currentURL ?? url
        guard let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return candidate
    }

    /// 用系统浏览器（Safari）打开当前页。
    ///
    /// 用户说的「加速」：系统浏览器有独立的持久缓存与内容拦截器，同一文档页在那边往往比内置
    /// `WKWebView` 更快；这也是本次只加按钮、不改 `WKWebViewConfiguration` 的原因（内置侧没有
    /// 明显且低风险的提速点，见简报）。
    private func openInSystemBrowser() {
        guard let target = systemBrowserURL else { return }
        UIApplication.shared.open(target, options: [:], completionHandler: nil)
    }
}

/// 内置浏览器的入口目标（也用于分享面板）：链接 + 标题
struct LinkShareTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL

    var items: [Any] { [url, title] }
}

/// 浏览器状态（标题 / 进度 / 当前地址）
@MainActor
final class BrowserModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentURL: URL?
    @Published var pageTitle: String?
}

private struct WebViewContainer: UIViewRepresentable {
    let model: BrowserModel
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = web
        context.coordinator.observe(web)
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: BrowserModel
        weak var webView: WKWebView?
        private var progressObservation: NSKeyValueObservation?

        init(model: BrowserModel) { self.model = model }

        func observe(_ web: WKWebView) {
            progressObservation = web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                let v = web.estimatedProgress
                Task { @MainActor in self?.model.progress = v }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.currentURL = webView.url
            model.pageTitle = webView.title
            model.progress = 1
        }

        /// 非 http(s) 的 scheme（itms-apps / itms-services 等）交给系统，其余一律留在内置网页里
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let scheme = target.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "about" {
                // v0.3.583：**主框架导航一发起就把当前地址换成目标页**。
                //
                // 原先只在 `didFinish` 更新 `currentURL` ⇒ 二次导航的**加载期间**它仍是上一页，
                // 此时点右上角「用系统浏览器打开」会打开**上一页**（复核发现的反例）。
                // 这里用 `navigationAction.request.url`（真实请求地址）而不是 `webView.url`
                // —— 后者在导航完成前不保证已切换。`about:` 是空白页，不作为可外开的地址。
                if navigationAction.targetFrame?.isMainFrame != false, scheme != "about" {
                    model.currentURL = target
                }
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(target, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
            }
        }
    }
}
