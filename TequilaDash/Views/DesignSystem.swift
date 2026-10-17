import CoreHaptics
import SwiftUI
import UIKit

/// Shared visual language for TequilaDash. Ported and adapted from 3105's
/// DesignSystem: a blue accent, a tinted rounded icon, and reclaim-specific
/// category styling. Uses TequilaDash's own model fields (no localization system).
///
/// ## 界面硬规则（用户明确要求，永久生效）
/// 1. **不要全宽实心色块 banner**（用户原话：「为什么那个 banner 是方块状的，我不喜欢这种方块」）。
///    深色品牌色**只出现在紧凑的连续圆角图标块**（`AppBrandTile`）里，不做全宽渐变填充 banner。
/// 2. **一律连续圆角**（`RoundedCornerStyle.continuous`）：卡片 `AppRadius.card`、图标块
///    `AppRadius.appIcon`、行内图标底 `AppRadius.icon`；不要直角、不要纯方。
/// 3. **按钮一律「半透明着色 + 发丝描边」**（`TintedButtonStyle`）：主行动用
///    `TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button)`，次要动作用默认号。
///    不用纯蓝实底，**也不用全宽深色渐变实底**（见硬规则 7）。
/// 4. 界面文案一律英文句点 `.`，不用中文句号，不用符号化标记 / 星形符号。
/// 5. **设置类列表用全宽行 + 发丝分隔**（`AppSettingsRow` + `AppHairline`），**不要套 16 圆角卡片**
///    （TRApp 设置页实测：行底 / 分隔线均全宽 0–828px；规范 §1.4 / §③组件 5）。
/// 6. **颜色一律明暗两套值**：品牌实测色写死 sRGB 时必须用 `Color(UIColor { trait in ... })`
///    给出深色分支；浅色专用的浅底（如空态圆 `emptyStateCircleFill`）在深色下必须换深色值，
///    不得沿用浅色字面量（否则深色模式出现刺眼亮块）。防复发见 `swift_theme_blue_guard.py` G4。
/// 7. **不用全宽深色实底按钮**（用户原话：「那个开始修复按钮颜色太丑了」）。大面积深色 +
///    全宽 ⇒ 突兀，尤其深藏青渐变（`brandGradient`）铺满一整行时像一块「深色板」。深色品牌色
///    只允许出现在**紧凑的连续圆角图标块**（`AppBrandTile`）里。主行动按钮改用
///    `TintedButtonStyle`（半透明着色 + 发丝描边）。防复发见 `swift_theme_blue_guard.py` G7。
enum AppTheme {
    /// Brand accent. Unified blue: TRApp-measured `#005493` in light mode,
    /// a brightened `#76D6FF` in dark mode for contrast.
    ///
    /// 统一「两套蓝」（决定见简报 §③）：此前全局 `accent` 是 `systemBlue`、新页面另用写死的
    /// `trAccent`（`#005493`），同页出现两套蓝（`I4MobileInstallView` heroChip 用 accent、
    /// sectionHeader 用 trAccent）。现合并为**单一自适应 token**：亮 `#005493`（TRApp 实测
    /// Accent）、暗 `#76D6FF`（提亮保证对比度）；`trAccent` 已删除，调用点全部改用 `accent`.
    /// 仍走 `Color(UIColor { trait in ... })` 随明暗模式自适应，不写死单值.
    static let accent = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x76 / 255, green: 0xD6 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x54 / 255, blue: 0x93 / 255, alpha: 1)
    })
    /// 页面内容左右边距。TRApp 列表页实测 **20**（此前 16，见规范 §1.3）.
    static let pageInset: CGFloat = 20
    static let appIconSize: CGFloat = 44

    // MARK: - 语义状态色
    //
    // 全部取 UIKit 语义色，自动适配明暗模式. 此前共享转换模块跨模块借用了
    // `LocusTheme`（虚拟定位页主题），而 `LocusTheme` 是硬编码 sRGB、不随明暗
    // 模式变化，深色下对比度不足. 这四个 token 是让共享转换退出 `LocusTheme`
    // 的落点 —— 只新增实际用到的，不建完整的 spacing / typography / radius 体系.

    /// 已完成 / 已修补.
    static let success = Color(uiColor: .systemGreen)
    /// 待处理 / 待修补.
    static let pending = Color(uiColor: .systemOrange)
    /// 失败 / 错误.
    static let danger = Color(uiColor: .systemRed)
    /// 未选中态的图标灰（选择圈、占位图形）.
    static let unselected = Color.secondary.opacity(0.5)

    /// 安全评分色阶（v0.3.626 统一）.
    ///
    /// 此前「评分 → 颜色」有两套实现**且已漂移**：
    ///   · HomeView.swift:446-452 —— 蓝档 80+、黄档 60..<80、其余橙
    ///   · HealthCheckView.swift:145-147 —— 蓝档 90+、黄档 70+、其余橙
    /// 用户从主页点「立即体检」进去，**同一个分数颜色会变**（80 分在主页是蓝、在体检页是黄）。
    /// 两处还都用系统 .yellow / .orange（单值色，无明暗两套，违反规则 6）。
    ///
    /// 现在统一到这里：阈值取 90 / 70（体检页口径更严，且它是「评分」的权威页面），
    /// 颜色改用自适应 token —— 深色模式下提亮以保证对比度。
    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 90...: return success      // 优秀
        case 70..<90: return pending    // 一般
        default: return danger          // 需处理
        }
    }

    /// 评分档位文案（与 scoreColor 同一阈值，避免再次漂移）.
    static func scoreLabel(_ score: Int) -> String {
        switch score {
        case 90...: return "手机很安全，可继续优化"
        case 70..<90: return "安全状况良好"
        default: return "建议尽快体检"
        }
    }
    /// 选择圈图标尺寸（已导入 / 待修补 / 已修补三页共用）.
    static let selectionIconSize: CGFloat = 20

    // MARK: - TRApp 风格语义色（新增）
    //
    // 对照 TRApp 逆向结论（`P4_全能签逆向/_简报/逆向_TRApp的UI.md`）：TRApp 只有 7 个
    // 自定义语义色，其余全走系统语义色。本仓已有 success / pending / danger，这里补齐
    // warning / mark 两个缺口，口径与既有四个 token 一致（`Color(uiColor:)` 语义色，随
    // 明暗模式自适应，不写死 RGB）.

    /// 警示 / 需注意.
    static let warning = Color(uiColor: .systemYellow)
    /// 高亮 / 标记（强调性标注、关键数值底色）.
    static let mark = Color(uiColor: .systemPink)

    // MARK: - 品牌渐变（新增）
    //
    // 取自 TRApp AppIcon 解码实测：深藏青竖向渐变 `#2C3A6A → #161F2E` + 纯白图形.
    // **仅供紧凑的连续圆角图标块 `AppBrandTile` 使用**（硬规则 1 / 7）：不作为全局 accent，
    // **更不用于按钮填充**（大面积深色 + 全宽 ⇒ 突兀，用户已明确反馈）。hero 是深色品牌底，
    // 与蓝色强调色并存，不参与「两套蓝」的统一（那是 `accent` 与 `trAccent` 的事，现已合并到
    // `accent`）.

    /// 品牌深藏青（TRApp AppIcon 实测主色 `#2C3A6A`）.
    static let brandNavy = Color(red: 0x2C / 255, green: 0x3A / 255, blue: 0x6A / 255)
    /// 品牌渐变（`#2C3A6A → #161F2E`，竖向）.
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0x2C / 255, green: 0x3A / 255, blue: 0x6A / 255),
            Color(red: 0x16 / 255, green: 0x1F / 255, blue: 0x2E / 255)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - TRApp 实测语义色（本轮从 Assets.car 解出）
    //
    // 上一轮只拿到命名色的**名称**；本轮用 `car-unpacker-py`（纯 Python，BOMStore + RLOC
    // float64 分量）解 `Assets.car`，拿到 TRApp 7 个命名色的**真实 RGB**（取自 flat-ui 调色板）。
    // 这是品牌实测值，故直接写死 sRGB；**仅供新页面使用**，不动既有 `success/pending/danger/
    // warning/mark`（那四个仍走系统语义色，全 App 影响面大）.
    // 证据：`P4_全能签逆向/_简报/实现_TRApp风格落地爱思移动端页.md` §①.
    //
    // ⚠️ `trAccent`（原 `#005493`）已删除：它与全局 `accent` 构成「两套蓝」，现统一到
    // `accent`（亮 `#005493` / 暗 `#76D6FF`），全部调用点改用 `accent`；防复发见
    // `Resources/Scripts/swift_theme_blue_guard.py`.

    /// TRApp 成功色（实测 `#6AB04C`）.
    static let trSuccess = Color(red: 0x6A / 255, green: 0xB0 / 255, blue: 0x4C / 255)
    /// TRApp 失败色（实测 `#E74C3C`）.
    static let trDanger = Color(red: 0xE7 / 255, green: 0x4C / 255, blue: 0x3C / 255)
    /// TRApp 警示色（实测 `#F9CA24`）.
    static let trWarning = Color(red: 0xF9 / 255, green: 0xCA / 255, blue: 0x24 / 255)
    /// TRApp `#008974`（**规范更名**：`Assets.car` 里此值实名 `BetaBadgeColor`，不是「可恢复」语义）.
    /// 本仓既有代码把它当**青绿强调色**用（图标底 / 次级强调），此名保留以不改动既有引用；
    /// 语义上它是 TRApp 的 Beta 徽章色，非状态色.
    static let trRecoverable = Color(red: 0x00 / 255, green: 0x89 / 255, blue: 0x74 / 255)
    /// TRApp Beta 徽章色（实测 `#008974`，与 `trRecoverable` 同值；此名为规范正名）.
    static let trBetaBadge = Color(red: 0x00 / 255, green: 0x89 / 255, blue: 0x74 / 255)
    /// TRApp 标记色（实测 `#F9CA24`，与警示同值）.
    static let trMark = Color(red: 0xF9 / 255, green: 0xCA / 255, blue: 0x24 / 255)

    // MARK: - 完整规范补充色（本轮落「巨魔录音机完整规范」）
    //
    // 下列 token 取自规范 §1.1 / §1.4 / §③：开关 ON 色、品牌青绿、空状态配色。均为 `.car`
    // 实测 sRGB（品牌实测值，故写死）。语义状态色 `success/pending/danger/warning/mark`
    // 维持系统语义色不动：它们被既有页面引用、且是随明暗模式自适应的语义色，全 App 替换
    // 影响面大且非本次目标（规范亦承认「新页面用 tr* 实测值」）。

    /// 开关 ON 色（TRApp 实测 `#005493`，`UISwitch.onTintColor` = Accent；规范 §③组件 6）.
    /// 即统一后的 `accent`（亮 `#005493` / 暗 `#76D6FF`）；单独命名以便设置页
    /// `Toggle.tint(AppTheme.switchOnTint)` 语义清晰.
    static let switchOnTint = accent

    /// 品牌青绿（TRApp 实测 `#008974`，`Assets.car` 内实名 `BetaBadgeColor`；规范 §1.1）.
    /// 与 `brandNavy`（深藏青）并列的次级品牌强调色；与 `trBetaBadge` / `trRecoverable` 同值.
    static let brand = Color(red: 0x00 / 255, green: 0x89 / 255, blue: 0x74 / 255)

    /// 空状态大圆底色（TRApp IMG_0079 实测 ≈ `#E0EBFE` 浅蓝；规范 §1.1 / §③组件 3）.
    /// **明暗两套值**：浅色用 TRApp 实测 `#E0EBFE`；深色不得沿用浅蓝（在深背景上是一块刺眼亮斑），
    /// 改用**低饱和深蓝灰** `#1C2C3E`，与深色分组背景有轻微层次又不抢视线.
    static let emptyStateCircleFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x1C / 255, green: 0x2C / 255, blue: 0x3E / 255, alpha: 1)
            : UIColor(red: 0xE0 / 255, green: 0xEB / 255, blue: 0xFE / 255, alpha: 1)
    })

    /// 空状态圆内字形色（TRApp IMG_0079 实测 ≈ `#56A376` 青绿；规范 §1.1 / §③组件 3）.
    /// **明暗两套值**：浅色用 TRApp 实测 `#56A376`；深色提亮到 `#7DD6A9`，在 `#1C2C3E` 圆底上
    /// 对比充分（相对亮度比 ≈ 8.9:1）.
    static let emptyStateGlyph = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x7D / 255, green: 0xD6 / 255, blue: 0xA9 / 255, alpha: 1)
            : UIColor(red: 0x56 / 255, green: 0xA3 / 255, blue: 0x76 / 255, alpha: 1)
    })

    // MARK: - 多色板系统（本轮新增：解决「颜色单一」）
    //
    // 背景：用户反馈「全面改造 TequilaDash 的 UI 风格…更不要单一的颜色」。此前全站只有
    // 一个强调蓝（`accent`）+ 少量系统语义色，各功能模块之间没有颜色区分 ⇒ 观感单一。
    // 本组 token 建立**三层色彩层次**，全部 `Color(UIColor { trait in ... })` 明暗两套：
    //   ① 模块色 `categoryXxx` —— 一个功能模块一个颜色，用于该模块的图标底 / 标题强调；
    //   ② 表面层 `surfaceXxx` —— base / card / elevated / sunken 四级背景，撑起卡片层次；
    //   ③ 强调变体 `accentSoft` / `accentBorder` —— 主强调色的淡填充与描边。
    // 硬规则（见文件头 1 / 7）：仍不做全宽深色实底；模块色只用于**紧凑图标块 / 小控件**，
    // 不铺满整行。防复发：`Resources/Scripts/swift_theme_blue_guard.py` G8 校验下列新增
    // 色 token 均为自适应色（定义体内出现 `userInterfaceStyle` + `.dark`）.

    // ── ① 模块色（一个功能模块一个颜色）──
    //
    // 取值口径：浅色用中深饱和（在浅背景上有对比），深色用同色相**提亮版**（在深背景上不糊）.
    // 用法：`AppRowIcon(tint:)` / `SizePill(tint:)` / 标题强调；只作用于紧凑控件.

    /// 清理与优化模块色（青绿）.
    static let categoryClean = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x4F / 255, green: 0xD8 / 255, blue: 0xC4 / 255, alpha: 1)
            : UIColor(red: 0x0E / 255, green: 0x8F / 255, blue: 0x7E / 255, alpha: 1)
    })
    /// 设备与系统模块色（靛蓝）.
    static let categoryDevice = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x9D / 255, green: 0xAA / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x3B / 255, green: 0x4C / 255, blue: 0xC0 / 255, alpha: 1)
    })
    /// 扩展与商店模块色（青蓝）.
    ///
    /// ⚠️ 此前为**橙棕** `#C2620E`（HSL 28° / 86% / 41%）——用户原话「我不喜欢棕色的颜色
    /// 主页你踩雷了，特别是你看"扩展与商店"那两个选区的颜色，你不许用棕色」。棕 = 低明度暖橙，
    /// 且本 token 常以 ~15% 透明度铺在浅底上（`AppRowIcon` 图标底）⇒ 叠出**米褐色**，正是用户
    /// 看到的「棕」。修法：整族移出暖区，改用**冷青蓝** `#0B8FC9`（HSL 198° / 90% / 42%），
    /// 低透明度铺底得到浅蓝，彻底去棕；与「设备与系统」被认可的冷色语言同源.
    static let categoryStore = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x5C / 255, green: 0xC6 / 255, blue: 0xF0 / 255, alpha: 1)
            : UIColor(red: 0x0B / 255, green: 0x8F / 255, blue: 0xC9 / 255, alpha: 1)
    })
    /// 百宝箱模块色（紫）.
    static let categoryTreasure = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xC3 / 255, green: 0xA6 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x7A / 255, green: 0x3B / 255, blue: 0xE0 / 255, alpha: 1)
    })
    /// 设置模块色（石板灰）.
    static let categorySettings = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xA9 / 255, green: 0xB3 / 255, blue: 0xC2 / 255, alpha: 1)
            : UIColor(red: 0x5A / 255, green: 0x64 / 255, blue: 0x72 / 255, alpha: 1)
    })
    /// 下载管理模块色（蓝）.
    static let categoryDownload = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x6F / 255, green: 0xC3 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x0A / 255, green: 0x6B / 255, blue: 0xD1 / 255, alpha: 1)
    })
    /// 签名 / 安装模块色（粉）.
    static let categorySign = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x8F / 255, blue: 0xB4 / 255, alpha: 1)
            : UIColor(red: 0xCE / 255, green: 0x32 / 255, blue: 0x68 / 255, alpha: 1)
    })
    /// 高级功能 / 逆向模块色（正红）.
    ///
    /// ⚠️ 此前为**砖红** `#BF3A2B`（HSL 6° / 63% / 46%）—— 低明度砖红在浅底上显**陶土棕**，
    /// 同属用户禁用的暖棕族。改用**正红** `#E5342B`（HSL 3° / 78% / 53%）：提高明度与饱和度，
    /// 落在「鲜明红」而非「棕红」区间；深色分支维持提亮的珊瑚红 `#FF8C7C`.
    static let categoryAdvanced = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x8C / 255, blue: 0x7C / 255, alpha: 1)
            : UIColor(red: 0xE5 / 255, green: 0x34 / 255, blue: 0x2B / 255, alpha: 1)
    })

    // ── ② 表面层（四级背景，撑起卡片层次）──
    //
    // base → sunken → card → elevated，从最底到最浮；相邻两级有**轻微**明度差，够分层但不抢眼.

    /// 页面底色（最底层）.
    static let surfaceBase = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x0E / 255, green: 0x11 / 255, blue: 0x16 / 255, alpha: 1)
            : UIColor(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF7 / 255, alpha: 1)
    })
    /// 卡片底（内容层）.
    static let surfaceCard = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x1B / 255, green: 0x1F / 255, blue: 0x26 / 255, alpha: 1)
            : UIColor(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255, alpha: 1)
    })
    /// 浮起层（Sheet / 悬浮条，比卡片更亮）.
    static let surfaceElevated = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x25 / 255, green: 0x2A / 255, blue: 0x33 / 255, alpha: 1)
            : UIColor(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255, alpha: 1)
    })
    /// 下沉层（内嵌槽 / 分组头，比卡片更暗）.
    static let surfaceSunken = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x15 / 255, green: 0x18 / 255, blue: 0x1E / 255, alpha: 1)
            : UIColor(red: 0xE9 / 255, green: 0xEB / 255, blue: 0xF0 / 255, alpha: 1)
    })

    // ── ③ 强调变体（主强调色的淡填充与描边）──
    //
    // 与 `accent.opacity(...)` 同色相，但**写死明暗两套**，避免深色下低透明度叠加出脏色.

    /// 强调色淡填充（图标底 / 按钮低饱和底）.
    static let accentSoft = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x16 / 255, green: 0x30 / 255, blue: 0x3D / 255, alpha: 1)
            : UIColor(red: 0xDC / 255, green: 0xEB / 255, blue: 0xFA / 255, alpha: 1)
    })
    /// 强调色描边（给淡底补一条清晰边界）.
    static let accentBorder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x4C / 255, green: 0x7E / 255, blue: 0x9C / 255, alpha: 1)
            : UIColor(red: 0x8A / 255, green: 0xB4 / 255, blue: 0xD6 / 255, alpha: 1)
    })

    // ── ④ 渐变组（仅用于紧凑图标块 / hero 强调，不做全宽实底）──
    //
    // 三组渐变，全部由**已自适应的模块色**构成 ⇒ 明暗两套自动成立，不新增写死字面量.
    // 用途边界（硬规则 1 / 7）：只用于紧凑连续圆角图标块（类 `AppBrandTile`）、hero 内小色块；
    // **不用于全宽按钮 / 全宽 banner**（`brandGradient` 仍是唯一深色品牌渐变，仅供 `AppBrandTile`）.

    /// 冷色渐变组（蓝 → 青）：hero / 大图标块.
    static let gradientCool = LinearGradient(
        colors: [categoryDownload, categoryClean],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 暖色渐变组（粉 → 红）：暖色模块图标块.
    ///
    /// ⚠️ 此前为 `[categoryStore, categorySign]`（橙 → 粉）；`categoryStore` 已去棕改为冷青蓝，
    /// 若沿用则「暖色渐变」名不副实（青→粉）。故改由**两个仍在暖区、且都已去棕**的模块色构成：
    /// 签名粉 `categorySign`（HSL 338°）→ 高级正红 `categoryAdvanced`（HSL 3°），保持暖色语义.
    static let gradientWarm = LinearGradient(
        colors: [categorySign, categoryAdvanced],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 紫靛渐变组（靛 → 紫）：次级模块图标块.
    static let gradientViolet = LinearGradient(
        colors: [categoryDevice, categoryTreasure],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 功能模块 → 模块色（多色板系统）：供页面按模块取色，避免各处手挑颜色.
///
/// 每个 case 对应 App 的一个功能板块，`tint` 即该模块的主色（取自 `AppTheme.categoryXxx`，
/// 全部明暗两套）。用法示例：`AppRowIcon(systemName: "sparkles", tint: AppModule.clean.tint)`。
enum AppModule {
    case clean, device, store, treasure, settings, download, sign, advanced

    /// 该模块的主色（明暗自适应）.
    var tint: Color {
        switch self {
        case .clean: return AppTheme.categoryClean
        case .device: return AppTheme.categoryDevice
        case .store: return AppTheme.categoryStore
        case .treasure: return AppTheme.categoryTreasure
        case .settings: return AppTheme.categorySettings
        case .download: return AppTheme.categoryDownload
        case .sign: return AppTheme.categorySign
        case .advanced: return AppTheme.categoryAdvanced
        }
    }
}

/// 「透明淡蓝」按钮样式（用户审美：不要纯蓝实底，要淡一点的蓝底）.
///
/// 只加这一个样式，不另造体系：前景取品牌蓝 `AppTheme.accent`（自适应 `#005493` / `#76D6FF`），
/// 背景取**同一色低透明度** —— 与 `AppRowIcon` / `SizePill` /
/// `PackageChip` / `ImportFlowBanner` 的 `tint.opacity(...)` 是同一口径（本仓既有的
/// 「淡底 + 同色前景」语言）。全程**不写死 RGB**，只用语义色 + 不透明度.
///
/// 与 `.borderedProminent` 的差别：后者是**实底**（用户不喜欢的纯蓝背景），本样式是**淡底**。
///
/// 明暗辨识度（本轮修正）：固定 12% 淡底在**深色背景**上几乎与背景同色，按钮边界辨识度弱。
/// 故按 `colorScheme` 分档：浅色维持 12%，深色提到 22%（按下再提一档作为反馈，替代实底样式的
/// 自动变暗）；并补一圈**发丝描边**（同为 `tint` 语义色），即便淡底与背景相近也有一条清晰边界.
///
/// 与同排次要按钮（`.bordered`）的风格对齐（本轮修正）：圆角 10 → 8（对齐系统 `.bordered` 常规号）、
/// 字号 `subheadline`(15) → `body`(17)（对齐 `.bordered` 的默认字号）、常规号竖向内边距 8 → 6
/// （使总高 ≈ `.bordered` 的 34pt）。小号（卡片内动作，无 `.bordered` 同排）维持原度量.
struct TintedButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent
    /// 圆角覆盖：`nil` 时按 `controlSize` 取既有默认（小号 7 / 常规 8）. 传 `AppRadius.button`
    /// （12）可对齐 TRApp 大按钮口径（如主页 hero 的「立即体检」）.
    var radius: CGFloat? = nil

    /// 参数类型必须写具体名 `ButtonStyleConfiguration`、不能写 `Configuration`：
    /// 本模块里 `vendor/ApplePackage` 另有一个 `public enum Configuration`，它在模块作用域里
    /// **盖过**了 `ButtonStyle.Configuration` ⇒ 裸写 `Configuration` 会解析成那个枚举，
    /// 报「cannot convert value of type 'Configuration' to expected argument type
    /// 'ButtonStyleConfiguration'」（v0.3.585 首次 CI 实测）。
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        TintedBody(configuration: configuration, tint: tint, radiusOverride: radius)
    }

    /// 样式体单独成一个 `View`：只有 `View` 能读 `@Environment`，用它在**禁用**时降透明度
    /// （自定义 `ButtonStyle` 不会像 `.borderedProminent` 那样自动置灰）.
    ///
    /// 名字**不能**叫 `Body`：`ButtonStyle` 有名为 `Body` 的关联类型，同名嵌套类型会被当成
    /// 那个关联类型去匹配协议要求，而它又是 `private` ⇒ 报
    /// 「struct 'Body' must be as accessible as its enclosing type」（同一次 CI 实测）。
    private struct TintedBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        var radiusOverride: CGFloat? = nil
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.colorScheme) private var colorScheme

        /// 尺寸随 `controlSize` 缩放：小号用于卡片内动作，常规号用于批量底条.
        private var small: Bool { controlSize == .small }
        /// 圆角与同排 `.bordered` 次要按钮对齐：常规号取 8（系统 `.bordered` 常规号口径）；
        /// 显式传入 `radiusOverride` 时以覆盖值为准.
        private var radius: CGFloat { radiusOverride ?? (small ? 7 : 8) }
        private var hPad: CGFloat { small ? 10 : 14 }
        /// 常规号 6：配合 `body` 字号使总高 ≈ `.bordered` 常规号的 34pt，同排不显高矮不齐.
        private var vPad: CGFloat { small ? 5 : 6 }
        /// 深色下淡底几乎与背景同色 ⇒ 不透明度分档；浅色维持既有 12% 口径.
        private var fillOpacity: Double { colorScheme == .dark ? 0.22 : 0.12 }
        private var pressedOpacity: Double { colorScheme == .dark ? 0.34 : 0.24 }
        /// 发丝描边不透明度：给淡底补一条清晰边界（同为 `tint` 语义色，不写死 RGB）.
        private var strokeOpacity: Double { colorScheme == .dark ? 0.45 : 0.25 }

        var body: some View {
            configuration.label
                // 常规号对齐 `.bordered` 默认字号（body），小号（卡片内动作）维持 subheadline.
                .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(tint.opacity(configuration.isPressed ? pressedOpacity : fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(tint.opacity(strokeOpacity), lineWidth: 0.5)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

/// Tinted rounded-rectangle icon used for category rows in the reclaim views.
struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = 17
    var frameSize: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

/// 品牌图标块（TRApp AppIcon 语言）：深藏青渐变底 + 连续圆角的**紧凑方图块**，内嵌白色 SF Symbol.
///
/// **用途**：页面头部替代「全宽渐变 banner」——深色品牌色只出现在这个小的圆角图标块里，
/// 不做全宽实心填充（用户明确不喜欢全宽方块 banner）。对照 TRApp：设置页无 hero、直接大标题 +
/// 卡片分组；欢迎页 App 图标就是一个深色大圆角方块。标题 / 副标题走页面背景上的主 / 次字色。
struct AppBrandTile: View {
    let systemName: String
    /// 图标块边长（默认 `AppMetrics.appIconTile`）.
    var size: CGFloat = AppMetrics.appIconTile
    /// 内嵌 SF Symbol 字号.
    var symbolSize: CGFloat = 26
    /// 圆角（默认 `AppRadius.appIcon`）.
    var radius: CGFloat = AppRadius.appIcon

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AppTheme.brandGradient)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(.white)
                .appSymbol()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A card with a tinted icon, title, message, and optional action button.
/// Used for empty / error / prompt states across the app so every tab shares
/// the same visual language.
struct InfoActionCard: View {
    let icon: String
    var iconTint: Color = AppTheme.accent
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppRowIcon(systemName: icon, tint: iconTint, symbolSize: 20, frameSize: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = actionTitle, let action = action {
                    // 统一「透明淡蓝」（本轮修正）：此前默认走 `.borderedProminent` + `.tint(accent)`
                    // 实底，深色模式下 accent（亮 `#76D6FF`）会变成**亮蓝实底**（对比突兀、违反
                    // 「不用纯蓝实底按钮」硬规则）。故本卡动作按钮一律用 `TintedButtonStyle`，
                    // 并去掉了原 `actionTinted` 开关（两分支等价，开关已无意义）.
                    Button(action: action) {
                        Text(actionTitle)
                    }
                    .buttonStyle(TintedButtonStyle())
                    .controlSize(.small)
                    .disabled(disabled)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// 行内错误提示（v0.3.630 新增）.
///
/// ## 为什么要有它
/// 全仓错误提示的**渲染方式**有 4 套并存（审计实证）：
///   · \`@State errorText\` + 内联 Text —— 20 个文件
///   · \`@State errorMessage\` + 内联 Text —— 30 个文件（且 \`String?\` 与 \`""\` 两种类型混用）
///   · 内联 \`.foregroundStyle(.red/.orange)\` 着色 —— 63 处 / 39 文件
///   · \`InfoActionCard\` + 重试 —— 33 处 / 21 文件（最规范）
///
/// 同一句「读不出来」，有的红色、有的灰色；有的 footnote、有的 callout；
/// 有的居中、有的左对齐 —— 用户在不同页面看到不同形态。
///
/// ## 用法
/// \`\`\`swift
/// if let error = loadError {
///     AppErrorRow(message: error)
/// }
/// // 或带重试：
/// AppErrorRow(message: error, retry: { reload() })
/// \`\`\`
///
/// ## 为什么用 pending（橙）而不是 danger（红）
/// 列表/数据读不出来通常是「隧道没通 / 配对文件缺失 / 网络抖动」这类**可恢复**问题，
/// 红色会让用户以为设备坏了或数据损坏了。真正不可恢复的才用 danger。
/// 这与 \`AppStateSection.error\` 的取色一致。
struct AppErrorRow: View {
    let message: String
    /// 可选重试动作。给了就显示「重试」按钮。
    var retry: (() -> Void)? = nil
    /// 是否居中。列表内的行内错误默认左对齐；整页空态场景可居中。
    var centered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.pending)
                .appSymbol()
            VStack(alignment: centered ? .center : .leading, spacing: 6) {
                Text(message)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("重试", action: retry)
                        .buttonStyle(TintedButtonStyle(tint: AppTheme.pending))
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// 列表的「加载 / 错误 / 空」三态统一容器（v0.3.626 新增）.
///
/// ## 为什么要有它
/// 全仓这三种状态有 **4 套并存**的写法（审计实证）：
///   · `AppEmptyState`（规范组件）—— 业务只用 2 页
///   · `ContentUnavailableView`（系统）—— 7 个文件
///   · `InfoActionCard`（当空态用）—— 21 个文件
///   · **裸 `Text("暂无…")` —— 26 处 / 21 文件**（最不规范的那种反而最多）
/// 加载态更是 136 处裸 `ProgressView()` 散在 70 个文件里。
///
/// ## 正确形态的来源
/// `BackupsListView.swift:109-137` 是全仓唯一把三态做得一致的地方 ——
/// 三态**全部用 InfoActionCard**，错误态还带重试动作。本组件就是它的抽象。
///
/// ## 用法
/// ```swift
/// AppStateSection(state: .loading("正在加载备份…", detail: "读取 Backups 目录."))
/// AppStateSection(state: .error("无法读取备份", message: error) { vm.reload() })
/// AppStateSection(state: .empty("暂无备份", message: "…"))
/// // 三态都不成立时返回 nil，调用方直接不渲染
/// ```
///
/// 判据：**只渲染状态，不渲染内容**。调用方按
/// `if let s = AppStateSection.state(...) { s } else { 真实内容 }` 使用。
struct AppStateSection: View {
    /// 三态之一。每一态都自带默认图标与色调，调用方可覆盖。
    enum State {
        /// 正在加载
        case loading(_ title: String, detail: String? = nil)
        /// 出错（可选重试动作）
        case error(_ title: String, message: String, retry: (() -> Void)? = nil)
        /// 空列表
        case empty(_ title: String, message: String? = nil, icon: String = "tray.full")
    }

    let state: State

    var body: some View {
        switch state {
        case .loading(let title, let detail):
            card(icon: "arrow.triangle.2.circlepath",
                 tint: AppTheme.accent,
                 title: title,
                 message: detail ?? "",
                 actionTitle: nil,
                 action: nil)

        case .error(let title, let message, let retry):
            // 错误态用 pending（橙）而不是 danger（红）：
            // 列表读不出来通常是「隧道没通 / 配对文件缺失」这类可恢复问题，
            // 红色会让用户以为设备坏了。真危险操作才用 danger。
            card(icon: "info.circle",
                 tint: AppTheme.pending,
                 title: title,
                 message: message,
                 actionTitle: retry == nil ? nil : "重试",
                 action: retry)

        case .empty(let title, let message, let icon):
            card(icon: icon,
                 tint: AppTheme.accent,
                 title: title,
                 message: message ?? "",
                 actionTitle: nil,
                 action: nil)
        }
    }

    private func card(icon: String, tint: Color, title: String,
                      message: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        Section {
            InfoActionCard(icon: icon,
                           iconTint: tint,
                           title: title,
                           message: message,
                           actionTitle: actionTitle,
                           action: action)
        }
    }
}

/// A small pill that highlights a byte count with a tinted background.
struct SizePill: View {
    let text: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 全宽发丝分隔线（TRApp 设置列表语言）：全宽、`0.5pt` 级细线.
///
/// 对照规范 §1.4 / §③组件 5：TRApp 设置列表是**全宽行 + ~2px 发丝分隔**（行底 `#F1EFF3` /
/// 分隔 `#E6E4E8`，均全宽 0–828px），**非内缩圆角卡片**. 本组件即那条分隔线，默认取系统分隔色.
struct AppHairline: View {
    /// 线高（默认 0.5pt = @2x 下 1px 真发丝；TRApp 实测约 1pt，可按需传 1）.
    var height: CGFloat = 0.5
    var color: Color = Color(uiColor: .separator)

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// 设置行（TRApp 设置列表语言，IMG_0081 / IMG_0083）：**全宽行 + 发丝分隔**，非内缩圆角卡片.
///
/// 结构（规范 §③组件 5 / 组件 6）：左图标（≈22pt）→ 标题（17pt semibold）+ 关键词副标题
/// （13pt 次字色，多值用「 / 」连接）→ 右侧 chevron（次字色，右边距 22pt）。行高参考
/// `AppMetrics.rowHeight`（≈84，含 1 行副标题），内容左右边距 `AppSpacing.settingsInset`（22）。
/// 行底可附一条全宽发丝分隔 `AppHairline`.
struct AppSettingsRow: View {
    /// 左侧 SF Symbol 名.
    let icon: String
    let title: String
    /// 关键词副标题（多值，组件内用「 / 」连接）.
    var keywords: [String] = []
    /// 是否显示右箭头（TRApp 设置行默认显示）.
    var showsChevron: Bool = true
    /// 右侧小徽章文案（如付费「$」；TRApp 为 19pt 灰圆徽章）.
    var badge: String? = nil
    /// 行底是否附全宽发丝分隔.
    var showsSeparator: Bool = true
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.titleToSubtitle) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(.primary)
                    if !keywords.isEmpty {
                        Text(keywords.joined(separator: " / "))
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: AppSpacing.row)
                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
            .padding(.horizontal, AppSpacing.settingsInset)
            .frame(minHeight: AppMetrics.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            if showsSeparator {
                AppHairline()
            }
        }
    }
}

/// 空状态（TRApp IMG_0079 语言）：**118pt 浅蓝圆 + 青绿字形 + 20pt 标题 + 一句俏皮副标题**，垂直居中.
///
/// 对照规范 §③组件 3：`.car` 内**无** placeholder 图片资源 ⇒ 空状态插画是**运行时 SF Symbols
/// 组合**（`waveform` + `magnifyingglass`）。本组件即用两层 SF Symbol 叠加还原该「波形 + 放大镜」。
/// 文案由调用方传入（副标题可俏皮，如 TRApp 原味「这里，只有空气」）.
struct AppEmptyState: View {
    /// 主字形（默认 `waveform`）.
    var icon: String = "waveform"
    /// 右下角次级字形（默认 `magnifyingglass`；传 `nil` 只显示主字形）.
    var secondaryIcon: String? = "magnifyingglass"
    let title: String
    /// 一句俏皮副标题.
    let message: String

    var body: some View {
        VStack(spacing: AppSpacing.section) {
            ZStack {
                Circle()
                    .fill(AppTheme.emptyStateCircleFill)
                    .frame(width: AppMetrics.emptyStateIcon, height: AppMetrics.emptyStateIcon)
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(AppTheme.emptyStateGlyph)
                if let secondaryIcon {
                    Image(systemName: secondaryIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppTheme.emptyStateGlyph)
                        .offset(x: 18, y: 18)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: AppSpacing.tight) {
                Text(title)
                    .font(AppFont.emptyStateTitle)
                Text(message)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.section)
    }
}

// MARK: - TRApp 风格 token 层（新增）
//
// 对照 TRApp 逆向结论：全站 SF Rounded（`design: .rounded`）+ Dynamic Type、
// 连续圆角、毛玻璃、数字等宽、分层符号渲染。以下把字号/圆角/间距收成命名 token，
// 供**新页面**使用；既有页面内联的字号与圆角**保持不变**（不一次全改，避免大范围回归）.

/// 字体层：SF Rounded + Dynamic Type，数字场景走等宽.
enum AppFont {
    static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title = Font.system(.title2, design: .rounded).weight(.bold)
    static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.system(.body, design: .rounded)
    static let bodyEmphasis = Font.system(.body, design: .rounded).weight(.semibold)
    static let subheadline = Font.system(.subheadline, design: .rounded)
    static let subheadlineEmphasis = Font.system(.subheadline, design: .rounded).weight(.semibold)
    /// 副标题号（13pt，TRApp 设置列表副标题实测值，规范 §1.2）.
    static let footnote = Font.system(.footnote, design: .rounded)
    static let footnoteEmphasis = Font.system(.footnote, design: .rounded).weight(.semibold)
    static let caption = Font.system(.caption, design: .rounded)
    static let captionEmphasis = Font.system(.caption, design: .rounded).weight(.semibold)
    /// 行 / 卡片标题号（17pt semibold，TRApp 设置行实测；规范 §1.2）. 与 `headline` 同值，
    /// 此名为语义正名，供设置行等场景使用.
    static let rowTitle = Font.system(.headline, design: .rounded).weight(.semibold)
    /// Tab 标签号（10pt，TRApp Tab bar 实测；规范 §1.2 / §③组件 4）. Tab 标签为固定字号，
    /// 不随 Dynamic Type 缩放（与系统 Tab bar 行为一致）.
    static let tabLabel = Font.system(size: 10, weight: .medium, design: .rounded)
    /// 空状态标题号（20pt bold，TRApp 空态实测；规范 §1.2 / §③组件 3）.
    static let emptyStateTitle = Font.system(.title3, design: .rounded).weight(.bold)
    /// 数字等宽：进度百分比、体积、倒计时等数字场景（TRApp 用 `.monospacedDigit()`）.
    static let number = Font.system(.body, design: .rounded).monospacedDigit()
    static let numberEmphasis = Font.system(.body, design: .rounded).weight(.semibold).monospacedDigit()
    static let numberSmall = Font.system(.caption, design: .rounded).monospacedDigit()
    /// 次标题号等宽数字（机型序列号 / 版本号等「值」列）.
    static let numberSubheadline = Font.system(.subheadline, design: .rounded).monospacedDigit()
    static let numberSubheadlineEmphasis = Font.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit()
}

/// 圆角层：连续圆角（`RoundedCornerStyle.continuous`），与既有卡片口径对齐.
enum AppRadius {
    /// 卡片圆角（对齐既有 heroCard 的 16）.
    static let card: CGFloat = 16
    /// 内层容器 / 次级卡片.
    static let inner: CGFloat = 12
    /// chip / 小控件（对齐 `TintedButtonStyle` 常规号 8）.
    static let chip: CGFloat = 8
    /// 行内图标底（对齐 `AppRowIcon` 的 7）.
    static let icon: CGFloat = 7
    /// 品牌图标块（`AppBrandTile`）圆角：紧凑方图块，比行内图标底更圆（TRApp AppIcon 比例）.
    static let appIcon: CGFloat = 16
    /// 大按钮圆角（TRApp「继续」按钮实测 ≈12，规范 §1.4）.
    static let button: CGFloat = 12
    /// 搜索框圆角（TRApp 搜索框实测 ≈10，规范 §1.4）.
    static let searchField: CGFloat = 10
    /// 底部 Sheet 顶角圆角（TRApp 欢迎页 Sheet 实测 ≈26，规范 §1.4）.
    static let sheet: CGFloat = 26
}

/// 间距层：区块 / 行 / 紧凑三档 + 完整规范实测间距.
enum AppSpacing {
    /// 区块之间.
    static let section: CGFloat = 16
    /// 行内元素之间.
    static let row: CGFloat = 12
    /// 紧凑元素之间.
    static let tight: CGFloat = 6
    /// 卡片 / 行标题 → 副标题（TRApp 实测 14；规范 §1.3）.
    static let titleToSubtitle: CGFloat = 14
    /// 开关行右侧留白（TRApp 实测 18；规范 §1.3 / §③组件 6）.
    static let switchTrailing: CGFloat = 18
    /// 设置列表内容左右边距（TRApp 实测 22；规范 §1.3 / §③组件 5）.
    static let settingsInset: CGFloat = 22
}

/// 阴影层（v0.3.626 新增）.
///
/// 此前 DesignSystem 里**没有任何阴影 token** —— 全仓只有 3 处硬编码 shadow
/// （MapDropPin.swift:34、JoystickPad.swift:23、VirtualLocationView.swift:197）。
/// 卡片层次全靠「底色 + 发丝描边」表达，这在浅色模式够用，
/// 但深色模式下 surfaceCard(#1B1F26) 与 surfaceBase(#0E1116) 明度差很小，
/// 卡片边界主要靠 accentBorder 0.30 的描边撑着，观感偏平。
///
/// 这里只补**两级**阴影，不做完整体系（与 AppRadius 的克制口径一致）：
/// - card：卡片浮起（浅色下极淡，深色下几乎不可见 —— 深色靠描边，这是对的）
/// - raised：浮层 / 拖拽中的元素（如 MapDropPin 拖拽态）
///
/// 判据：阴影只在**浅色模式**有意义；深色模式用描边而非阴影，
/// 因为深色背景上的黑色阴影只会让边缘糊成一片脏带（本仓 hero 卡曾踩过同类坑）。
enum AppShadow {
    /// 卡片投影：浅色下极淡（黑 6%，radius 8，y 2），深色下不投影.
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.06)
    }
    /// 卡片投影半径.
    static let cardRadius: CGFloat = 8
    /// 卡片投影垂直偏移.
    static let cardY: CGFloat = 2

    /// 浮层投影（拖拽 / 悬浮）：两种模式都用，但深色下更重一些以保证可见.
    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.18)
    }
    /// 浮层投影半径.
    static let raisedRadius: CGFloat = 12
    /// 浮层投影垂直偏移.
    static let raisedY: CGFloat = 4
}

/// 卡片背景 token（v0.3.626 新增）.
///
/// 此前 `appCard()` 内部**硬取** `Color(uiColor: .secondarySystemGroupedBackground)`
/// （DesignSystem.swift:842），于是全仓出现 4 种卡片底取色路径：
///   · `.appCard()` —— 8 个文件
///   · 手拼 `RoundedRectangle + Color(.secondarySystemGroupedBackground)` —— 21 个文件
///   · `Color(.systemGroupedBackground)`（页面底色）—— 10 个文件
///   · `AppTheme.surfaceCard` / `surfaceBase` —— 4 个文件
/// 同一条「卡片」硬规则有两套落地方式。
///
/// 现在把「卡片底」提升为显式 token，`appCard()` 改为引用它；
/// 页面若要自定义卡片底（如 HomeToolTile 的模块色渐变），
/// 应该在**这个底之上叠加**，而不是另取一个系统色。
enum AppSurface {
    /// 卡片底色（跟随系统 grouped 背景，明暗自适应）.
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    /// 页面底色（跟随系统 grouped 背景，明暗自适应）.
    static let page = Color(uiColor: .systemGroupedBackground)
    /// 卡片描边（发丝，0.5pt 用）.
    static let cardBorder = Color(uiColor: .separator)
}

/// 尺寸层：卡片内边距与图标尺寸.
enum AppMetrics {
    /// 卡片内边距.
    static let cardPadding: CGFloat = 16
    /// 行内图标底边长（对齐 `AppRowIcon` 默认 30）.
    static let iconSize: CGFloat = 30
    /// hero 区块图标边长.
    static let heroIconSize: CGFloat = 44
    /// 品牌图标块边长（页面头部 `AppBrandTile` 默认值）.
    static let appIconTile: CGFloat = 56
    /// 列表行高参考值（TRApp 设置列表行实测 ≈85，含 1 行副标题；规范 §1.4）.
    static let rowHeight: CGFloat = 84
    /// 空状态圆形大图标直径（TRApp 空态实测 118，浅蓝底 + 青绿字形；规范 §1.4）.
    static let emptyStateIcon: CGFloat = 118
    /// 大按钮高度（TRApp「继续」按钮实测 44；规范 §1.4 / §③组件 1）.
    static let buttonHeight: CGFloat = 44
}

/// 触觉层：方法在**调用侧**执行，不持有非 Sendable 的静态生成器实例（Swift 6 严格并发）.
enum AppHaptics {
    /// 轻点反馈（工具行点击等）：瞬时、较强.
    @MainActor
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.8)
    }

    /// 成功反馈.
    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 失败反馈.
    @MainActor
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// 关键动作反馈（安装开始 / 录音开始 / 成功确认等）：照 TRApp `RecordingStarts.ahap` 曲线 ——
    /// **Transient(intensity 0.8 / sharpness 0.4) + Continuous(0.25s, 0.8 / 0.4)**，叠加强度衰减曲线
    /// `1 → 0.5 → 0` 与锐度曲线 `0 → -0.3`（规范 §1.5）。硬件不支持 CoreHaptics 时退回 `.rigid`
    /// 单次冲击，保证始终有反馈.
    @MainActor
    static func keyAction() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
            return
        }
        do {
            let engine = try sharedEngine()
            try engine.start()
            let player = try engine.makePlayer(with: Self.keyActionPattern())
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
        }
    }

    /// CoreHaptics 引擎单例. `@MainActor` 隔离：`CHHapticEngine` 非 `Sendable`，Swift 6 严格并发下
    /// 只能在主 actor 上持有；`isAutoShutdownEnabled` 让引擎空闲自动停机，无需手动 `stop()`.
    @MainActor private static var engine: CHHapticEngine?

    @MainActor
    private static func sharedEngine() throws -> CHHapticEngine {
        if let existing = engine { return existing }
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true
        newEngine.isAutoShutdownEnabled = true
        engine = newEngine
        return newEngine
    }

    /// TRApp `RecordingStarts.ahap` 曲线：瞬时 + 0.25s 连续，强度 / 锐度各一条控制曲线.
    @MainActor
    private static func keyActionPattern() throws -> CHHapticPattern {
        let transient = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            ],
            relativeTime: 0
        )
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            ],
            relativeTime: 0,
            duration: 0.25
        )
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.125, value: 0.5),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.25, value: 0.0)
            ],
            relativeTime: 0
        )
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.25, value: -0.3)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(
            events: [transient, continuous],
            parameterCurves: [intensityCurve, sharpnessCurve]
        )
    }
}

/// 卡片底：语义分组背景 + 连续圆角 + 统一内边距.
struct AppCardBackground: ViewModifier {
    var radius: CGFloat = AppRadius.card
    var padding: CGFloat = AppMetrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
    }
}

/// 毛玻璃底（TRApp `Material.ultraThin` 语言），用于浮层 / 悬浮条.
struct AppGlassBackground: ViewModifier {
    var radius: CGFloat = AppRadius.card

    func body(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }
}

/// SF Symbol 分层渲染（TRApp `.symbolRenderingMode(.hierarchical)` 语言）.
struct AppSymbol: ViewModifier {
    func body(content: Content) -> some View {
        content.symbolRenderingMode(.hierarchical)
    }
}

extension View {
    /// 统一卡片外观（语义背景 + 连续圆角 + 内边距）.
    func appCard(radius: CGFloat = AppRadius.card, padding: CGFloat = AppMetrics.cardPadding) -> some View {
        modifier(AppCardBackground(radius: radius, padding: padding))
    }

    /// 统一毛玻璃外观.
    func appGlass(radius: CGFloat = AppRadius.card) -> some View {
        modifier(AppGlassBackground(radius: radius))
    }

    /// SF Symbol 分层渲染.
    func appSymbol() -> some View {
        modifier(AppSymbol())
    }
}

// MARK: - Reclaim category styling

extension ReclaimRisk {
    /// Visual role color: safe = green, session = amber, kept = grey.
    var tint: Color {
        switch self {
        case .safe: return Color.green
        case .session: return Color.orange
        case .kept: return Color.secondary
        }
    }
}

extension ReclaimCategory {
    /// SF Symbol matching each reclaim bucket, mirroring 3105's intent.
    /// The runtime `UIImage(systemName:)` guard protects against missing
    /// glyphs on older iOS builds (observed: `cookie` not rendering on some
    /// iOS 18.0 devices), falling back to a safe generic icon so the row
    /// never shows a blank tile.
    var symbol: String {
        switch id {
        case "tmp": return "clock"
        case "caches": return "internaldrive"
        case "logs": return "doc.text"
        case "splash": return "photo"
        case "gpucache": return "cpu"
        case "cookies":
            return safeSymbol(named: "cookie", fallback: "doc.text")
        case "http": return "globe"
        case "webkit": return "safari"
        case "savedstate": return "arrow.clockwise"
        case "documents": return "doc"
        case "preferences": return "gearshape"
        case "appsupport": return "folder"
        default: return "questionmark"
        }
    }

    private func safeSymbol(named primary: String, fallback: String) -> String {
        UIImage(systemName: primary) != nil ? primary : fallback
    }
}

// MARK: - Sharing

/// Identifiable wrapper for a file URL we want to share.
struct ShareTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet (`UIActivityViewController`) for exporting a file
/// via AirDrop, Files, etc.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
