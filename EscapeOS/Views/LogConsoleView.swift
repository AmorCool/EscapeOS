import SwiftUI
import UIKit
import Darwin

/// 控制台式日志视图 —— 排版参考 YangJiiii/3105 的 `LogView.swift`。
///
/// 与我方旧日志页（**一整块 `Text`**）的差别，也正是这个视图存在的理由：
/// 1. **逐行一个 `Text` + 行间 `Divider`** —— 长日志才能逐行定位、逐行选中，
///    而不是糊成一坨（旧版就是一坨，用户看着累）；
/// 2. **新日志到达时自动滚到底**（尊重「减弱动态效果」）；
/// 3. **工具栏四件套**：清除 / 复制（带 1.5s 对勾反馈）/ 分享 / 完成，
///    各日志页从此长得一样（此前四页各写各的）；
/// 4. **复制内容带元信息头**（App 名 + iOS 版本(build) + 机型 + 生成时间）——
///    贴给开发者时不必再反问「哪个版本、哪台机器」。
///
/// 按 `CORE.md` 铁律 4（界面只留必要信息）**不搬** 3105 的东西：
/// 空状态的那句说明文字（"…将显示在这里"）与 footer 文案，一律不要 ——
/// 空状态只留**图标 + 一句极短占位**。
struct LogConsoleView: View {

    /// 逐行日志（**新的在后面**）。调用方按 `maxRenderedLines` 取数即可（见该常量说明）。
    let lines: [String]

    /// 导航标题；同时作为复制/分享文本的抬头。
    let title: String

    /// 「清除」回调。`nil` = 不显示清除按钮（日志不可清空的页面用）。
    var onClear: (() -> Void)? = nil

    /// 「完成」回调。`nil` = 不显示完成按钮
    /// —— 页面本身是 `NavigationLink` push 出来的（已有系统返回按钮）时用这个，避免两个等价按钮。
    var onDone: (() -> Void)? = nil

    /// 「清除」的二次确认标题。`nil` = 点了直接清。
    ///
    /// 清空日志**不可恢复**（会把日志文件一起删掉），所以凡是有清除按钮的页面都该传这个 ——
    /// 五个日志页统一都有确认，别让某一页静默丢历史。
    var clearConfirmTitle: String? = nil

    /// **渲染上限：只渲染最近这么多行。**
    ///
    /// 为什么必须有这个上限：逐行 `Text` 意味着**每一行都是一个独立的 SwiftUI 视图**，
    /// `LazyVStack` 虽然只为可见区建视图，但 `ForEach` 的 diff 与滚动条的估算高度
    /// 仍按整个数组算 —— 上万行时（`LoginLogger.logText` 的读法上限就是 10_000 行）
    /// 会明显卡顿、内存抬升，**比旧版「一整块 `Text`」更吃资源**（这是照搬 3105 排版的
    /// 唯一代价，用截断把它按住）。2000 行足够覆盖一次完整的下载/登录排查过程，
    /// 更早的内容本来就只能靠复制/分享出去看。
    static let maxRenderedLines = 2000

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var showShare = false
    @State private var showClearConfirm = false

    /// 实际渲染的行。数据层已按上限取过数，这里是**兜底**：
    /// 保证任何调用方（含以后接进来的另外三个日志页）都不可能把超量行丢进 `LazyVStack`。
    private var visibleLines: [String] {
        lines.count > Self.maxRenderedLines ? Array(lines.suffix(Self.maxRenderedLines)) : lines
    }

    /// 复制/分享用的文本 = **元信息头** + 正文。
    /// 正文用 `visibleLines`，保证「复制出来的」和「屏幕上看到的」是同一批行。
    private var shareText: String {
        let build = sysctlString("kern.osversion") ?? "?"
        let machine = sysctlString("hw.machine") ?? "?"
        var out: [String] = []
        out.append("\(Self.appName) — \(title)")
        out.append("iOS \(UIDevice.current.systemVersion) (\(build)) — \(machine)")
        out.append(Self.stamp())
        out.append("")
        out.append(contentsOf: visibleLines)
        return out.joined(separator: "\n")
    }

    var body: some View {
        Group {
            if visibleLines.isEmpty {
                emptyState
            } else {
                console
            }
        }
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClear {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清除", role: .destructive) {
                        // 有确认标题就先弹确认（清空不可恢复），没传则保持旧 AppStoreLogView 的直接清
                        if clearConfirmTitle != nil {
                            showClearConfirm = true
                        } else {
                            onClear()
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = shareText
                    copied = true
                    // 1.5s 后复原图标（3105 同款反馈）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(visibleLines.isEmpty)

                // 分享的是**文本**（带元信息头），不是文件 —— 便于直接贴给开发者。
                // 这里走 `ShareSheet`（`LoginLogView` 同款）而不是 `ShareLink`：
                // 本仓库里 `ShareLink` 只以**文件 URL** 用过（`ModuleManagerView`），
                // 而 `ShareSheet(items: [String])` 是有先例的写法，风险更低。
                Button {
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(visibleLines.isEmpty)

                if let onDone {
                    Button("完成") { onDone() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
        // 未传 `clearConfirmTitle` 时永远不会触发（按钮走直接清那条路），
        // 所以这里给个空标题不会露出来。
        .confirmationDialog(clearConfirmTitle ?? "", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) { onClear?() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 主体

    /// 空状态：**只有图标 + 一句极短占位**。
    /// 3105 这里还有一行说明句，按 `CORE.md` 铁律 4 不搬（说明文字不放界面）。
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("暂无日志")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // `id: \.offset`（下标）与 3105 一致：日志行**经常整句重复**
                    // （同一句错误刷屏），拿内容当 id 会撞车；下标在「只追加」的
                    // 控制台语义下是稳定的。
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                        VStack(spacing: 0) {
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 11)

                            // 最后一行下面不画分隔线（3105 同款）
                            if index < visibleLines.count - 1 {
                                Divider()
                            }
                        }
                        .id(index)
                    }
                }
                .padding(AppTheme.pageInset)
            }
            // 打开页面时**直接定位到最后一行**。只靠下面的 `onChange` 不够：首次进入时
            // 行数还没有「变化」过（`onChange` 不触发），页面会停在最旧的一行 ——
            // 而控制台的语义是「最新在底部」。3105 没有这一步，是它漏掉的。
            .onAppear {
                guard !visibleLines.isEmpty else { return }
                proxy.scrollTo(visibleLines.count - 1, anchor: .bottom)
            }
            .onChange(of: visibleLines.count) { _, count in
                // 只在**行数变化**时滚到底。
                // 外层日志页是 2s 轮询、每次重新赋值数组；`onChange` 只在值真的变了才触发，
                // 所以「没有新日志」时不会把正在往上翻的用户拽回底部，来了新行才滚
                // （3105 就是这个语义，照搬）。
                guard count > 0 else { return }
                let last = count - 1
                if reduceMotion {
                    proxy.scrollTo(last, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 元信息头

    /// 本 App 的名字 + 版本。
    ///
    /// 用 `Bundle(for:)` 而不是 `Bundle.main`：在 LiveContainer 里 `Bundle.main` 指向宿主
    /// App，取不到我们的 Info.plist（`CORE.md` 已定案）。`BundleAnchor` 只是用来定位
    /// 「本文件所在的 bundle」的锚点。
    private static var appName: String {
        let bundle = Bundle(for: BundleAnchor.self)
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "EscapeOS"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "\(name) \(version)"
    }

    /// 生成时间。每次现建 `DateFormatter`（与 `LoginLogger.timestamp()` 一致）——
    /// 只在点「复制/分享」时走一次，省一个可能被并发访问的静态实例。
    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// `Bundle(for:)` 的锚点类（见 `appName`）。仅用于定位本 App 的 bundle ——
    /// 与 `NiuwaStoreClient.BundleToken` 同一个套路。
    private final class BundleAnchor {}
}

/// 读一个字符串型 sysctl（`hw.machine` / `kern.osversion`）。
///
/// 自己写而不是复用 `DeviceInfoService`：后者的取法是 `collectFull()`（会开 RSD 隧道、
/// 阻塞数秒），只为拼一行元信息头不值得；`KernelCacheService.deviceIdentifier()` 语义
/// 属于 kernelcache 下载，也不该被日志页借走。这里要的就是零权限、零阻塞的一次 sysctl。
private func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}
