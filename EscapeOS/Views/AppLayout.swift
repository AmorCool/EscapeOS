import SwiftUI
import UIKit

/// 布局与动效组件层（AppLayout）.
///
/// ## 为什么单独成层
/// 既有设计语言（`DesignSystem.swift`）只有**一种**列表语言：全宽行 + 发丝分隔
/// （`AppSettingsRow` / `AppHairline`）。设置类页面用它没问题，但**功能入口 / 内容流 / 详情页**
/// 全用它就会「一屏全是横条」，观感单调。本文件补上**另外四种布局模式**与一套动效系统，
/// 让不同语义的内容用不同骨架承载 —— 这是「布局要好看」的落点，也是「不是纯照抄巨魔录音机」
/// 的地方：TRApp 几乎只有分组全宽行，本仓在此之上扩展出自己的网格 / 横滑 / hero 语言。
///
/// ## 五种布局模式（什么时候用）
/// - **A 分组全宽行**（既有，`AppSettingsRow` / `HomeView.featureSection`）：设置项、开关、说明性列表 ——
///   每行一个「词条」，需要副标题 + 右箭头时。
/// - **B 卡片网格**（本文件 `AppCardGrid` + `AppGridTile`）：**平级的多个功能入口**（设备工具 6 项等）——
///   没有主次之分、彼此并列，用 2 列网格比 6 条横条更省纵向空间、更像「工具箱」。
/// - **C 横向滚动卡**（本文件 `AppHScrollSection`）：**推荐 / 最近使用 / 精选** —— 数量不定、只需扫一眼、
///   点进去才展开的次要内容，横滑不占用主纵向流。
/// - **D Hero + 内容**（本文件 `AppHeroHeader`）：**详情页首屏** —— 先给「这是什么」（品牌图标块 + 标题 +
///   关键 stat），再往下才是明细卡片。
/// - **E 自适应网格**（本文件 `AppAdaptiveGrid`）：**图片 / 图标 / 尺寸不定的条目流** —— 列宽由最小宽度
///   自动决定列数，横竖屏 / 不同机型都能铺满。
///
/// ## 硬规则对齐（不破坏既有语言）
/// - 卡片一律 `secondarySystemGroupedBackground` + 连续圆角（走既有 `.appCard()`）。
/// - 深色品牌色只出现在**紧凑连续圆角图标块** `AppBrandTile` 里（硬规则 1 / 7），不做全宽深色 banner。
/// - 按钮沿用 `TintedButtonStyle`（半透明着色 + 发丝描边），不用纯蓝实底。
/// - 颜色一律走 `AppTheme` 语义 token，不写死 RGB。
///
/// ⚠️ 本文件**只新增**组件与扩展，不改 `DesignSystem.swift` 任何既有符号；`AppHaptics` 用
/// `extension` 补方法（不改原类型定义），既有调用点不受影响.

// MARK: - 动效系统

/// 动效 token 层：把散落在各页的 `.spring(...)` 字面量收成命名曲线，保证全 App 节奏一致.
///
/// - `quick`：纯反馈（按下、高亮），无回弹.
/// - `snappy`：**默认** —— 列表项出现、卡片入场，短促利落.
/// - `bouncy`：强调性入场（hero、空态），回弹明显.
/// - `smooth`：布局变化（网格列数切换、展开/收起），缓而稳.
///
/// 用计算属性而非 `static let`：避免 Swift 6 严格并发下全局可变状态检查，且构造开销可忽略.
enum AppMotion {
    /// 纯反馈（按下 / 高亮），无回弹.
    static var quick: Animation { .easeOut(duration: 0.16) }
    /// 默认曲线：列表项 / 卡片入场.
    static var snappy: Animation { .spring(response: 0.30, dampingFraction: 0.86) }
    /// 强调曲线：hero / 空态，回弹明显.
    static var bouncy: Animation { .spring(response: 0.42, dampingFraction: 0.70) }
    /// 布局变化：网格 / 展开收起.
    static var smooth: Animation { .spring(response: 0.52, dampingFraction: 0.92) }

    /// 阶梯延迟的**项数上限**：超过它的项不再继续累加延迟.
    ///
    /// ⚠️ 为什么必须有上限（用户报「更多-拉起应用 上滑下滑都要反应一会」的根因之一）：
    /// 入场延迟按**绝对序号**累加，而懒加载容器是**滚入视野才创建单元格**。长列表（应用列表
    /// 可达上百项）滚到第 150 项时，延迟已是 `150 × 0.045 = 6.75s` —— 格子空白数秒才淡入。
    /// 封顶后最大延迟恒为 `staggerLimit × step`（默认 12 × 45ms ≈ 0.54s），与列表长度无关.
    static let staggerLimit = 12

    /// 阶梯延迟：第 `index` 项的入场延迟（默认每项 45ms，逐项递增，但**封顶** `staggerLimit` 项）.
    static func stagger(_ index: Int, step: Double = 0.045) -> Double {
        Double(max(0, min(index, staggerLimit))) * step
    }

    /// 第 `index` 项的入场动画（`snappy` + 阶梯延迟）.
    static func appear(_ index: Int) -> Animation {
        snappy.delay(stagger(index))
    }
}

/// 入场修饰符：从下方 14pt 淡入 + 上移到位，按 `index` 阶梯延迟.
///
/// 用法：列表 / 网格里 `content(item).appAppear(index: index)`，形成「依次浮现」的节奏.
///
/// ⚠️ 阶梯入场**只作用于首屏窗口内**的前 `staggerWindow` 项；窗口外的项**立即可见**.
/// 原因：本修饰符会用在 `AppAdaptiveGrid` / `AppCardGrid` 这类**懒加载**容器的单元格上 ——
/// 单元格是**滚入视野才创建**，而 `index` 是**绝对序号**。若对每个单元格都按 `index × 步长`
/// 延迟入场，长列表（应用列表可达上百项）滚到第 150 项时该格要等 ~6.75s 才淡入，表现就是
/// 「上滑下滑反应一会」（用户 2026-10-12 报「更多-拉起应用」）。故窗口外零延迟.
struct AppAppear: ViewModifier {
    var index: Int = 0
    var offset: CGFloat = 14
    /// 参与阶梯入场的项数窗口（首屏量级）；`index >= staggerWindow` 的项不做「隐藏 → 延迟淡入」.
    var staggerWindow: Int = 12
    @State private var shown: Bool

    init(index: Int = 0, offset: CGFloat = 14, staggerWindow: Int = 12) {
        self.index = index
        self.offset = offset
        self.staggerWindow = staggerWindow
        // 窗口外的项从创建起即「已显示」：不经历 透明度 0 → 延迟淡入，滚动时零等待.
        _shown = State(initialValue: index >= staggerWindow)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : offset)
            .onAppear {
                guard !shown else { return }
                withAnimation(AppMotion.appear(index)) { shown = true }
            }
    }
}

/// 按压修饰符样式：按下时轻微缩小 + 降透明度，松手回弹（微交互）.
///
/// 参数类型必须写全名 `ButtonStyleConfiguration`：本模块内另有一个 `Configuration` 枚举会盖过
/// `ButtonStyle.Configuration`（见 `DesignSystem.swift` 同名注释），裸写会解析错误.
struct AppPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(AppMotion.snappy, value: configuration.isPressed)
    }
}

/// SF Symbol 弹跳修饰符：`value` 变化时触发一次 `.bounce`（用于「有更新 / 已触发」的提示）.
struct AppSymbolBounce<V: Equatable>: ViewModifier {
    var value: V

    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: value)
    }
}

extension View {
    /// 入场动画（淡入 + 上移，按 `index` 阶梯延迟）.
    func appAppear(index: Int = 0, offset: CGFloat = 14) -> some View {
        modifier(AppAppear(index: index, offset: offset))
    }

    /// 按压微交互（按下缩小 + 降透明度）. 适用于自定义 label 的按钮.
    func appPressable(scale: CGFloat = 0.97) -> some View {
        buttonStyle(AppPressableStyle(scale: scale))
    }

    /// SF Symbol 弹跳（`value` 变化时触发一次）.
    func appSymbolBounce<V: Equatable>(value: V) -> some View {
        modifier(AppSymbolBounce(value: value))
    }
}

/// 触觉层扩展（不改 `DesignSystem.swift` 原类型，用 extension 补两个常用档）.
extension AppHaptics {
    /// 选择反馈（切换分段 / 选中网格项）：比 `tap()` 更轻.
    @MainActor
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 柔和冲击（卡片入场完成 / 轻微状态变化）.
    @MainActor
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }
}

// MARK: - 布局 A 的补充：分段标题（带品牌色竖条）

/// 分段标题（布局 A / B / C / E 通用）：**品牌色竖条 + 主标题 + 可选副标题 / 图标 / 右侧动作**.
///
/// 与 TRApp 的「次级字色小标题」不同 —— 这里用一条 3pt 品牌色胶囊做视觉锚点，标题走主字色，
/// 让分组在页面里**立得起来**（本仓自己的分段语言，不照抄 TRApp 的灰字小标题）.
///
/// 泛型 `Trailing` 让调用方挂右侧动作（如「全部」按钮）；不传时用 `EmptyView` 重载.
struct AppSectionHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String?
    private let trailing: Trailing

    init(_ title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(AppTheme.accent)
                .frame(width: 3, height: 16)
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .appSymbol()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppFont.subheadlineEmphasis)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

extension AppSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.init(title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

// MARK: - 布局 B：卡片网格

/// 卡片网格（布局 B）：`columns` 列等宽网格，逐项带阶梯入场动画.
///
/// 适用：**平级的多个功能入口**（无主次、彼此并列）。比一列全宽行更紧凑，观感更像「工具箱」.
/// 内容由调用方给（通常是 `AppGridTile`，也可包 `NavigationLink`）.
struct AppCardGrid<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    private let columns: Int
    private let spacing: CGFloat
    private let content: (Item) -> Content

    init(items: [Item],
         columns: Int = 2,
         spacing: CGFloat = 12,
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self.content = content
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, columns))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                content(item)
                    .appAppear(index: index)
            }
        }
    }
}

/// 网格卡片（布局 B 的单元）：连续圆角图标底 + 标题 + 可选副标题（最多 2 行）+ 可选右箭头.
///
/// 与全宽行（`AppSettingsRow`）的区别：**纵向堆叠**（图标在上、文字在下），2 列并排时读起来是
/// 「格子」而非「列表条」。等宽等高由网格行高对齐（`maxHeight: .infinity`）.
struct AppGridTile: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = AppTheme.accent
    var showsChevron: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                AppRowIcon(systemName: icon, tint: tint, symbolSize: 18, frameSize: 36)
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .appSymbol()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appCard(padding: 14)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

// MARK: - 布局 C：横向滚动卡

/// 横向滚动分区（布局 C）：分段标题 + 横向 `LazyHStack` 卡片.
///
/// 适用：**推荐 / 最近使用 / 精选** —— 数量不定、只需扫一眼的次要内容。不占用主纵向流.
/// `cardWidth` 控制每张卡宽度（默认 168）；卡片内容由调用方给.
/// 横向内边距不在此处添加，由外层容器统一控制，避免与页面 `pageInset` 叠加.
struct AppHScrollSection<Item: Identifiable, Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String?
    private let items: [Item]
    private let cardWidth: CGFloat
    private let content: (Item) -> Content

    init(title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         items: [Item],
         cardWidth: CGFloat = 168,
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.items = items
        self.cardWidth = cardWidth
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader(title, subtitle: subtitle, symbol: symbol)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: cardWidth)
                    }
                }
            }
        }
    }
}

// MARK: - 布局 D：Hero + 内容

/// Hero 关键指标（`AppHeroHeader` 的 stat 行单元）.
struct AppStat: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Hero 页头（布局 D）：**品牌图标块 + 标题 + 副标题 + 可选关键 stat 行**.
///
/// 适用：**详情页首屏** —— 先交代「这是什么」（紧凑深色品牌块 + 标题），再给一排关键数值，
/// 下方接明细卡片。深色品牌色只出现在 `AppBrandTile` 这个小圆角块里，**不做全宽深色 banner**
/// （硬规则 1 / 7）.
struct AppHeroHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String
    var stats: [AppStat] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppBrandTile(systemName: symbol, size: AppMetrics.appIconTile, symbolSize: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFont.title3)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !stats.isEmpty {
                HStack(spacing: 10) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value)
                                .font(AppFont.numberSubheadlineEmphasis)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(stat.label)
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.inner, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 布局 E：自适应网格

/// 自适应网格（布局 E）：列宽 `minimum` 起、列数自动 —— 横竖屏 / 不同机型都能铺满.
///
/// 适用：**图片 / 图标 / 尺寸不定的条目流**（应用图标墙、壁纸缩略图等）.
/// 与 `AppCardGrid` 的区别：`AppCardGrid` 固定列数（要「整齐的格子」），本组件让内容自己决定列数.
struct AppAdaptiveGrid<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    private let minimum: CGFloat
    private let spacing: CGFloat
    private let content: (Item) -> Content

    init(items: [Item],
         minimum: CGFloat = 104,
         spacing: CGFloat = 12,
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.minimum = minimum
        self.spacing = spacing
        self.content = content
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                content(item)
                    .appAppear(index: index)
            }
        }
    }
}
