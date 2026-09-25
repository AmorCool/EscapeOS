import Foundation

/// 整机（主板）序列号 -> 生产日期解码器（**纯本地**：不联网、不外发任何设备标识）.
///
/// ▸ 为什么改成离线：v0.3.530 的「生产日期」是 POST `https://app4.i4.cn/getProdate.xhtml`
///   拿到的（旧实现 `I4ProdateClient`），会把设备的 `ProductType` / `SerialNumber` / `mlbSerial`
///   发到爱思（第三方，非 Apple）服务器. 逆向实测证明：**服务端只是个解码器，不是它独有的数据库**
///   —— 同一公式在端侧即可算出，且输入（lockdown 的 `MLBSerialNumber`）本来就在设备上.
///   依据与实测见 `_i4_re/PRODATE_外发分析.md`. 本文件即该公式的端侧实现，
///   上线后整个 `I4ProdateClient.swift` 即可删除（已删）.
///
/// ▸ 算法（逐条对应 `_i4_re/PRODATE_外发分析.md` 第 1.3 节，服务端实测复现）：
///   1. 取 mlbSerial 的**第 4、5、6 个字符**（0 基下标 3、4、5）—— 即 `mlbSerial[3:6]`；
///      实测：逐位把真 MLB 改成 `'0'`，只有下标 3、4、5 会改变服务端结果，其余 15 位全不影响；
///   2. 这三个字符各查一次 base-34 字母表得到下标 i0、i1、i2；
///   3. `days = i0 * 34^2 + i1 * 34 + i2` —— 一个 34 进制的三位数；
///   4. 日期 = **1970-01-01（Unix 纪元）+ days 天**；
///   5. 周数 `week = floor((day_of_year - 1 + wday(1月1日)) / 7) + 1`，其中 `wday` 取周日 = 0.
///
/// ▸ 实测命中（`_i4_re/PRODATE_外发分析.md` 第 1.3 节，与爱思面板**逐字一致**）：
///   - 本机 MLB `F3XH89002VT00008LH`：`[3:6]="H89"` -> `17*1156 + 8*34 + 9 = 19933` 天
///     -> **2024-07-29**、周数 31 -> `2024年07月29日(第31周)`，与服务端返回逐字一致；
///   - 同机电池 SN `F8YH7Y22SC600006TY`：`[3:6]="H7Y"` -> 2024-07-18(第29周)，亦逐字一致；
///   - 服务端 4/4 预测命中（`H8A` / `H8B` / `H60` / `H50`）；
///   - 合成串也出日期（如全零串服务端回 `2019年12月29日(第1周)`）
///     => 服务端**不是查表**，是确定性解码器，故可离线复刻.
///
/// ▸ 与 `BatterySerialDate.swift` 的关系：那是**电池** SN 的本地解码器（爱思 PC 端 Path B：
///   取 2 个字符、权重 1156 / 35）；本文件是**整机（主板）** SN 的本地解码器（服务端同款：
///   取 3 个字符、权重 1156 / 34 / 1）. 两者是**两套不同**的算法，**不要互相套用**.
enum DeviceSerialDate {

    /// base-34 字母表：34 个字符 = 0-9 + 24 个大写字母，**只缺 I 和 O**（S、U 在表内）.
    /// 与 `_i4_re/PRODATE_外发分析.md` 第 1.3 节给出的服务端同款字母表逐字一致.
    private static let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// 整机（主板）序列号 -> 爱思面板同款字符串 `yyyy年MM月dd日(第W周)`；
    /// **解不出返回 nil**（调用方保持「未知」，不编默认值）.
    ///
    /// 返回 nil 的三种情形：
    ///   - 长度**必须恰好 18 位** —— 实测前缀截断（长度 2..16）服务端一律回「未知」；
    ///   - 第 4 个字符 `mlbSerial[3]` 是**数字** —— 服务端此时走**另一条分支**
    ///     （按「年 + 两位周」解，非本公式），该分支未完全破解. 若仍按本公式算，
    ///     全零串会得到 `1970-01-01`，而服务端实测是 `2019年12月29日(第1周)`；
    ///     **宁可显示「未知」也不要显示一个错的日期**（取舍同 `BatterySerialDate` 注释）；
    ///   - `[3:6]` 里任一字符**不在字母表**（如 `I` / `O` / 小写字母）—— 查表失败.
    ///
    /// ▸ 为什么不 `uppercased()`：字母表里**只有大写**，服务端对这三个字符也是逐字符查表、
    ///   不做大小写折叠. 万一序列号是小写，落到 nil 只是继续显示「未知」，
    ///   比「按错误的大小写规则凑出一个看似合理的日期」安全.
    ///
    /// ▸ 已知未复刻项（如实标注）：服务端对「落在未来」的日期会回「未知」
    ///   （如 `J00` -> 2026、`P00` -> 2042 均被拒），但其**精确的合理范围上下限未破解**
    ///   （见分析文档第 6 节「不确定项」），故本函数**不做范围闸门** ——
    ///   真机序列号解出的都是过去日期，不受影响.
    static func productionDate(from mlbSerial: String) -> String? {
        let chars = Array(mlbSerial)
        guard chars.count == 18 else { return nil }
        let c0 = chars[3]
        guard !c0.isNumber else { return nil }
        guard let i0 = alphabet.firstIndex(of: c0),
              let i1 = alphabet.firstIndex(of: chars[4]),
              let i2 = alphabet.firstIndex(of: chars[5]) else { return nil }

        // 34 进制的三位数：i0 权重 34^2、i1 权重 34、i2 权重 1.
        let days = i0 * 34 * 34 + i1 * 34 + i2
        let (year, month, day) = civilDate(fromDaysSinceUnixEpoch: days)
        let week = weekOfYear(year: year, daysSinceUnixEpoch: days)
        // 输出格式与爱思服务端 `prodate` 字段逐字对齐：`2024年07月29日(第31周)`（半角括号、无空格）.
        return "\(zeroPadded(year, width: 4))年\(zeroPadded(month, width: 2))月\(zeroPadded(day, width: 2))日(第\(week)周)"
    }

    /// 一年中的第几周（`week = floor((day_of_year - 1 + wday(1月1日)) / 7) + 1`，周日 = 0）.
    ///
    /// 依据：`_i4_re/PRODATE_外发分析.md` 第 1.3 节的周数公式. 该式对 6 个真机/服务端样本
    /// （第 31 / 29 / 20 / 15 周）逐条吻合，故照此实现，未用 `Calendar` 的 ISO 周.
    ///
    /// ▸ 为什么这样等价：把 `wday(1月1日)` 当作「1 月 1 日所在那周已过去的天数」，
    ///   `day_of_year - 1 + wday` 就是「从 1 月 1 日所在周的周日算起经过的天数」，
    ///   整除 7 再加 1 即为周序. 全整数运算，无时区依赖.
    ///
    /// ▸ 入参恒为 1..366 的合法 `day_of_year`，且本函数只在本文件的解码路径里被调用
    ///   （`year >= 2001`），故 `jan1 >= 0`、`%` 表现为非负取模，无需额外的负数修正项.
    private static func weekOfYear(year: Int, daysSinceUnixEpoch days: Int) -> Int {
        let jan1 = daysFromCivil(year: year, month: 1, day: 1)
        let dayOfYear = days - jan1 + 1                          // 1 基，[1, 366]
        // 1970-01-01 是周四 -> 周日为 0 的计数下，纪元当天 = 4.
        let jan1Weekday = (jan1 + 4) % 7                         // [0, 6]，周日 = 0
        return (dayOfYear - 1 + jan1Weekday) / 7 + 1
    }

    /// 零填充，等价于 `%04d` / `%02d`（爱思输出即带填充）.
    ///
    /// 刻意**不用** `String(format: "%04d", n)`：Swift 的 `Int` 是 64 位，而 `%d` 在 C 里是 32 位，
    /// 属于未定义行为（小值恰好能对，但没必要赌）. 本函数逻辑平凡，也就不会有时区/本地化干扰.
    private static func zeroPadded(_ value: Int, width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }

    /// 「距 1970-01-01 的天数」-> 公历年 / 月 / 日（**纯整数运算**，不碰 `Calendar`、不碰时区）.
    ///
    /// ▸ 为什么不用 `Calendar` / `DateFormatter` 把天数转成 `Date` 再格式化：
    ///   那个日期是**按整天**算出来的，一旦变成 `Date` 再按设备**本地时区**渲染，
    ///   在 UTC 以西的时区就会**少一天**（与 `BatterySerialDate.swift` 注释里记的是同一类坑）.
    ///   这里改成与时区无关的整数算法，结果与爱思的 `%04d-%02d-%02d` 对齐.
    ///
    /// ▸ 算法：Howard Hinnant 的 `civil_from_days`（`days_from_civil` 的逆）.
    ///   把纪元平移到 `0000-03-01` 起算（这样闰日永远落在「年尾」，月长序列变成常数），
    ///   以 400 年 = 146097 天为一个 era 整除，再用 365 / 闰年项修正还原年、月、日.
    ///   已用 Python 与 `datetime.date(1970,1,1) + timedelta(days: n)` 全量对拍
    ///   （`BatterySerialDate.swift` 记录 n ∈ [0, 40000)，0 处不一致）.
    ///
    /// ▸ 入参恒 `>= 0`（`[3]` 为字母 => i0 `>= 10` => days `>= 11560`），故**不需要**处理
    ///   负数取整 —— 这也是下面那个「向下取整」修正项被省掉的原因.
    private static func civilDate(fromDaysSinceUnixEpoch days: Int) -> (year: Int, month: Int, day: Int) {
        // 1970-01-01 距 0000-03-01 的天数 = 719468（Hinnant 原文常量）.
        let z = days + 719468
        let era = z / 146097                                             // 400 年一个 era
        let dayOfEra = z - era * 146097                                  // [0, 146096]
        // era 内第几年（[0, 399]）：先按 365 天近似，再用闰年项修正.
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)   // [0, 365]
        // 以 3 月为一年之始 => 闰日落在末尾，月长可以用常数公式反解.
        let monthPrime = (5 * dayOfYear + 2) / 153                       // [0, 11]
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1             // [1, 31]
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9    // [1, 12]
        // 1 月 / 2 月属于「上一个公历年」（上面把年起点挪到了 3 月）.
        return (month <= 2 ? year + 1 : year, month, day)
    }

    /// 公历年 / 月 / 日 -> 「距 1970-01-01 的天数」（`civil_from_days` 的正向，Hinnant `days_from_civil`）.
    ///
    /// 只被 `weekOfYear` 用来求「该年 1 月 1 日距纪元的天数」，从而拿到 `day_of_year` 与星期几.
    ///
    /// ▸ 入参恒 `year >= 2001`（见 `civilDate` 的入参说明），`month <= 2` 时 `y = year - 1 >= 2000`，
    ///   故 `y` 恒为正 —— Swift 的整数除法对正数就是向下取整，与 Hinnant 原文的 `floor` 一致，
    ///   不需要额外的负数修正项.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400                                    // [0, 399]
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146097 + dayOfEra - 719468
    }
}
