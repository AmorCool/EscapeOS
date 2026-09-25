import Foundation

/// v0.3.530：电池序列号 → 生产日期解码器（**纯本地**：不联网、不读漏洞利用、不需要特权）.
///
/// ▸ 来源（逆向实锤，见 `_i4_re/PRODATE_电池生产日期_结论.md`）：
///   爱思 9.0 `i4Tools.exe!0x140234430` 的 **Path B**（入口 `0x140234fa2`）.
///   爱思面板上那个「生产日期」就是这个函数本地算出来的 —— 不是服务端按序列号查的
///   （`getProdate.xhtml` 本机实测回「未知」），也不是型号表的 `ReleaseDate`
///   （那只在同函数 Path A 里当「十年位消歧」用）.
///   旁证：爱思还把同一结果当 `battDate` 参数上报服务端（`0x140dda0c4`），
///   即「先本地算，再上报」，方向与我们这里一致.
///
/// ▸ 算法（Path B，逐条对应反汇编）：
///   1. 取电池序列号的**第 4、5 个字符**（0 基下标 3、4）—— `0x140234fc8` / `0x140234fe1`；
///   2. 各查一次 base-34 字母表得到下标 i1、i2 —— `0x14023501c` / `0x1402350b0`；
///   3. `days = i1 * 1156 + i2 * 35` —— `0x140235155`（`*0x484`）/ `0x140235161`（`*0x23`）；
///   4. 日期 = **1970-01-01（Unix 纪元）+ days 天** —— `0x14023516d`（`*24*60*60`）
///      → `0x140235189` 调 `0x140224990`（秒 → 时间结构）；
///   5. 输出按 `%04d-%02d-%02d` 补零 —— `0x140235219` 格式串 / `0x14023525e` 等三处宽度 4/2/2.
///
/// ▸ 实测命中（**样本只有 1 台设备**）：
///   电池 SN `F8YH7Y22SC600006TY` → `[3]='H'`(下标 17)、`[4]='7'`(下标 7)
///   → `17 * 1156 + 7 * 35 = 19897` 天 → **2024-06-23**，与爱思界面逐字一致（含补零）.
///   同机 MLB `F3XH89002VT00008LH`（`[3][4]='H8'`）→ 19932 天 → 2024-07-28，
///   比电池晚 35 天（电池先造、整机后装，方向合理）.
///
/// ⚠️ **系数 1156 / 35 的语义未知**（如实标注，不要当成已证结论）：
///   `1156 = 34²` 说得通，但 `35` **不等于 34** —— 所以这**不是**标准 base-34 的
///   `i1 * 34 + i2`，两个系数是从反汇编里直接抄下来的常数，只有上面那 1 组真机样本验证过.
///   若日后某台设备算出的日期与爱思不符，**优先怀疑这两个系数**，而不是调用方.
///
/// ▸ 适用范围：反汇编里这条 base-34 分支只对 **18 位**标识（电池 SN / MLB SN）成立.
///   10 位整机 SN 走的是同一函数里的另一条链（Path A 的 QRegExp 分支），
///   用本公式去解会得到**早于该机型发布**的日期
///   （实测整机 `HP9GNP43P4` → 2022-10-01，早于 iPhone15,4 的 2023-09）.
///   ⇒ 调用方**只喂电池序列号**，不要把整机序列号递进来.
enum BatterySerialDate {

    /// base-34 字母表：34 个字符 = 0-9 + 24 个大写字母，**只缺 I 和 O**（S、U 在表内）.
    /// 与 `i4Tools.exe!0x140234fa2` 处硬编码的串逐字一致.
    private static let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// 下标 3 的权重：`1156`（= 34 * 34，反汇编 `0x140235155` 的 `0x484`）.
    private static let highWeight = 1156

    /// 下标 4 的权重：`35`（反汇编 `0x140235161` 的 `0x23`）.
    /// ⚠️ 语义未知：若是纯 base-34 应为 34，此处按反汇编取 35（见类型注释）.
    private static let lowWeight = 35

    /// 电池序列号 → `yyyy-MM-dd`；**解不出返回 nil**（调用方保持「未知」，不编默认值）.
    ///
    /// 返回 nil 的两种情形，与爱思 Path B 的两个前置判断一一对应：
    ///   - 序列号长度 < 5 —— 反汇编 `0x140234fb1`：`arg2.length() < 5` → 返回空；
    ///   - 第 4 或第 5 个字符**不在字母表里** —— 反汇编 `0x14023513a`：任一下标 == -1 → 返回空.
    ///
    /// ▸ 为什么不做 `uppercased()`：字母表里**只有大写**，而反汇编里那两次查表是逐字符比较、
    ///   **没有**大小写折叠（同一函数的 Path A 正则才显式带 CaseInsensitive 选项）.
    ///   故这里同样不改大小写 —— 万一序列号是小写，落到 nil 只是继续显示「未知」，
    ///   比「按错误的大小写规则凑出一个看似合理的日期」安全.
    static func productionDate(from serial: String) -> String? {
        let chars = Array(serial)
        guard chars.count >= 5 else { return nil }
        guard let i1 = alphabet.firstIndex(of: chars[3]),
              let i2 = alphabet.firstIndex(of: chars[4]) else { return nil }
        let days = i1 * highWeight + i2 * lowWeight
        let (year, month, day) = civilDate(fromDaysSinceUnixEpoch: days)
        return "\(zeroPadded(year, width: 4))-\(zeroPadded(month, width: 2))-\(zeroPadded(day, width: 2))"
    }

    /// 零填充，等价于 `%04d` / `%02d`（反汇编里爱思用的就是带填充的 `%1-%2-%3`）.
    ///
    /// 刻意**不用** `String(format: "%04d", n)`：Swift 的 `Int` 是 64 位，而 `%d` 在 C 里是 32 位，
    /// 属于未定义行为（小值恰好能对，但没必要赌）. 本函数逻辑平凡，也就不会有时区/本地化干扰.
    private static func zeroPadded(_ value: Int, width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }

    /// 「距 1970-01-01 的天数」→ 公历年 / 月 / 日（**纯整数运算**，不碰 `Calendar`、不碰时区）.
    ///
    /// ▸ 为什么不用 `Calendar` / `DateFormatter` 把天数转成 `Date` 再格式化：
    ///   那个日期是**按整天**算出来的，一旦变成 `Date` 再按设备**本地时区**渲染，
    ///   在 UTC 以西的时区就会**少一天**
    ///   （19897 天 = 2024-06-23 00:00 UTC，在 UTC-8 渲染成 2024-06-22 16:00 → 显示 06-22）.
    ///   爱思是在 Windows 本机时区上跑的，我们不该跟着设备时区漂 ——
    ///   这里改成与时区无关的整数算法，结果与爱思的 `%04d-%02d-%02d` 对齐.
    ///
    /// ▸ 算法：Howard Hinnant 的 `civil_from_days`（`days_from_civil` 的逆）.
    ///   把纪元平移到 `0000-03-01` 起算（这样闰日永远落在「年尾」，月长序列变成常数），
    ///   以 400 年 = 146097 天为一个 era 整除，再用 365 / 闰年项修正还原年、月、日.
    ///   已用 Python 与 `datetime.date(1970,1,1) + timedelta(days: n)` 全量对拍
    ///   （n ∈ [0, 40000)，0 处不一致）.
    ///
    /// ▸ 入参恒 `>= 0`（两个权重都为正、查表下标 `>= 0`），故**不需要**处理负数取整
    ///   —— 这也是下面那个「向下取整」修正项被省掉的原因.
    private static func civilDate(fromDaysSinceUnixEpoch days: Int) -> (year: Int, month: Int, day: Int) {
        // 1970-01-01 距 0000-03-01 的天数 = 719468（Hinnant 原文常量）.
        let z = days + 719468
        let era = z / 146097                                             // 400 年一个 era
        let dayOfEra = z - era * 146097                                  // [0, 146096]
        // era 内第几年（[0, 399]）：先按 365 天近似，再用闰年项修正.
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)   // [0, 365]
        // 以 3 月为一年之始 ⇒ 闰日落在末尾，月长可以用常数公式反解.
        let monthPrime = (5 * dayOfYear + 2) / 153                       // [0, 11]
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1             // [1, 31]
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9    // [1, 12]
        // 1 月 / 2 月属于「上一个公历年」（上面把年起点挪到了 3 月）.
        return (month <= 2 ? year + 1 : year, month, day)
    }
}
