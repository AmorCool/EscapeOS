import SwiftUI
import WebKit

/// App 内置网页浏览器（WKWebView）—— **不再静默跳转到外部 App / Safari**。
///
/// 顶部栏：标题 + 「分享链接」（`UIActivityViewController`）+ 关闭。
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareTarget = LinkShareTarget(title: model.pageTitle ?? title, url: model.currentURL ?? url)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $shareTarget) { ShareSheet(items: $0.items) }
        }
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
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(target, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
            }
        }
    }
}
