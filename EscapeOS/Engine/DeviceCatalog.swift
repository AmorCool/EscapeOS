import Foundation

/// v0.3.294：机型规格表（对齐爱思「设备详情」中的上市日期 / CPU / 屏幕等派生字段）
///
/// 说明：这些项**设备本身不返回**（爱思也是查它自己的机型库），
/// 故此处内置公开规格；屏幕分辨率/核心数/内存等仍优先取设备实时值
/// （`UIScreen.main.nativeBounds` / `hw.ncpu` / `hw.memsize`）。
struct DeviceSpec {
    var name: String            // 机型名
    var releaseDate: String     // 中国大陆发布日（爱思同口径）
    var cpu: String             // 处理器
    var cpuFrequency: String    // 主频（公开规格）
    var screenInches: String    // 屏幕尺寸（英寸）
}

enum DeviceCatalog {
    /// hw.machine / ProductType → 规格
    static let specs: [String: DeviceSpec] = [
        // iPhone 17 / 16 系列
        "iPhone18,1": DeviceSpec(name: "iPhone 17 Pro", releaseDate: "2025年9月10日", cpu: "Apple A19 Pro", cpuFrequency: "4.05GHz", screenInches: "6.3"),
        "iPhone18,2": DeviceSpec(name: "iPhone 17 Pro Max", releaseDate: "2025年9月10日", cpu: "Apple A19 Pro", cpuFrequency: "4.05GHz", screenInches: "6.9"),
        "iPhone18,3": DeviceSpec(name: "iPhone 17", releaseDate: "2025年9月10日", cpu: "Apple A19", cpuFrequency: "4.05GHz", screenInches: "6.3"),
        "iPhone18,4": DeviceSpec(name: "iPhone Air", releaseDate: "2025年9月10日", cpu: "Apple A19 Pro", cpuFrequency: "4.05GHz", screenInches: "6.5"),
        "iPhone17,1": DeviceSpec(name: "iPhone 16 Pro", releaseDate: "2024年9月10日", cpu: "Apple A18 Pro", cpuFrequency: "4.05GHz", screenInches: "6.3"),
        "iPhone17,2": DeviceSpec(name: "iPhone 16 Pro Max", releaseDate: "2024年9月10日", cpu: "Apple A18 Pro", cpuFrequency: "4.05GHz", screenInches: "6.9"),
        "iPhone17,3": DeviceSpec(name: "iPhone 16", releaseDate: "2024年9月10日", cpu: "Apple A18", cpuFrequency: "4.04GHz", screenInches: "6.1"),
        "iPhone17,4": DeviceSpec(name: "iPhone 16 Plus", releaseDate: "2024年9月10日", cpu: "Apple A18", cpuFrequency: "4.04GHz", screenInches: "6.7"),
        "iPhone17,5": DeviceSpec(name: "iPhone 16e", releaseDate: "2025年2月20日", cpu: "Apple A18", cpuFrequency: "4.04GHz", screenInches: "6.1"),
        // iPhone 15 系列
        "iPhone16,1": DeviceSpec(name: "iPhone 15 Pro", releaseDate: "2023年9月13日", cpu: "Apple A17 Pro", cpuFrequency: "3.78GHz", screenInches: "6.1"),
        "iPhone16,2": DeviceSpec(name: "iPhone 15 Pro Max", releaseDate: "2023年9月13日", cpu: "Apple A17 Pro", cpuFrequency: "3.78GHz", screenInches: "6.7"),
        "iPhone15,4": DeviceSpec(name: "iPhone 15", releaseDate: "2023年9月13日", cpu: "Apple A16", cpuFrequency: "3.46GHz", screenInches: "6.1"),
        "iPhone15,5": DeviceSpec(name: "iPhone 15 Plus", releaseDate: "2023年9月13日", cpu: "Apple A16", cpuFrequency: "3.46GHz", screenInches: "6.7"),
        // iPhone 14 系列
        "iPhone14,7": DeviceSpec(name: "iPhone 14", releaseDate: "2022年9月8日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "6.1"),
        "iPhone14,8": DeviceSpec(name: "iPhone 14 Plus", releaseDate: "2022年9月8日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "6.7"),
        "iPhone15,2": DeviceSpec(name: "iPhone 14 Pro", releaseDate: "2022年9月8日", cpu: "Apple A16", cpuFrequency: "3.46GHz", screenInches: "6.1"),
        "iPhone15,3": DeviceSpec(name: "iPhone 14 Pro Max", releaseDate: "2022年9月8日", cpu: "Apple A16", cpuFrequency: "3.46GHz", screenInches: "6.7"),
        // iPhone 13 系列
        "iPhone14,5": DeviceSpec(name: "iPhone 13", releaseDate: "2021年9月15日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "6.1"),
        "iPhone14,4": DeviceSpec(name: "iPhone 13 mini", releaseDate: "2021年9月15日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "5.4"),
        "iPhone14,2": DeviceSpec(name: "iPhone 13 Pro", releaseDate: "2021年9月15日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "6.1"),
        "iPhone14,3": DeviceSpec(name: "iPhone 13 Pro Max", releaseDate: "2021年9月15日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "6.7"),
        // iPhone 12 系列
        "iPhone13,1": DeviceSpec(name: "iPhone 12 mini", releaseDate: "2020年10月14日", cpu: "Apple A14", cpuFrequency: "3.10GHz", screenInches: "5.4"),
        "iPhone13,2": DeviceSpec(name: "iPhone 12", releaseDate: "2020年10月14日", cpu: "Apple A14", cpuFrequency: "3.10GHz", screenInches: "6.1"),
        "iPhone13,3": DeviceSpec(name: "iPhone 12 Pro", releaseDate: "2020年10月14日", cpu: "Apple A14", cpuFrequency: "3.10GHz", screenInches: "6.1"),
        "iPhone13,4": DeviceSpec(name: "iPhone 12 Pro Max", releaseDate: "2020年10月14日", cpu: "Apple A14", cpuFrequency: "3.10GHz", screenInches: "6.7"),
        // iPhone 11 / SE
        "iPhone12,1": DeviceSpec(name: "iPhone 11", releaseDate: "2019年9月11日", cpu: "Apple A13", cpuFrequency: "2.65GHz", screenInches: "6.1"),
        "iPhone12,3": DeviceSpec(name: "iPhone 11 Pro", releaseDate: "2019年9月11日", cpu: "Apple A13", cpuFrequency: "2.65GHz", screenInches: "5.8"),
        "iPhone12,5": DeviceSpec(name: "iPhone 11 Pro Max", releaseDate: "2019年9月11日", cpu: "Apple A13", cpuFrequency: "2.65GHz", screenInches: "6.5"),
        "iPhone12,8": DeviceSpec(name: "iPhone SE (2nd)", releaseDate: "2020年4月15日", cpu: "Apple A13", cpuFrequency: "2.65GHz", screenInches: "4.7"),
        "iPhone14,6": DeviceSpec(name: "iPhone SE (3rd)", releaseDate: "2022年3月9日", cpu: "Apple A15", cpuFrequency: "3.23GHz", screenInches: "4.7"),
        // iPhone X / XS / XR
        "iPhone11,2": DeviceSpec(name: "iPhone XS", releaseDate: "2018年9月13日", cpu: "Apple A12", cpuFrequency: "2.49GHz", screenInches: "5.8"),
        "iPhone11,4": DeviceSpec(name: "iPhone XS Max", releaseDate: "2018年9月13日", cpu: "Apple A12", cpuFrequency: "2.49GHz", screenInches: "6.5"),
        "iPhone11,6": DeviceSpec(name: "iPhone XS Max", releaseDate: "2018年9月13日", cpu: "Apple A12", cpuFrequency: "2.49GHz", screenInches: "6.5"),
        "iPhone11,8": DeviceSpec(name: "iPhone XR", releaseDate: "2018年9月13日", cpu: "Apple A12", cpuFrequency: "2.49GHz", screenInches: "6.1"),
        "iPhone10,3": DeviceSpec(name: "iPhone X", releaseDate: "2017年9月13日", cpu: "Apple A11", cpuFrequency: "2.39GHz", screenInches: "5.8"),
        "iPhone10,6": DeviceSpec(name: "iPhone X", releaseDate: "2017年9月13日", cpu: "Apple A11", cpuFrequency: "2.39GHz", screenInches: "5.8"),
    ]

    static func spec(_ machine: String) -> DeviceSpec? { specs[machine] }

    /// 机型名（优先规格表；退化到旧的友好化处理）
    static func name(_ machine: String) -> String {
        if let s = specs[machine] { return s.name }
        if machine.hasPrefix("iPhone") {
            return "iPhone " + machine.dropFirst("iPhone".count)
        }
        if machine.hasPrefix("iPad") { return "iPad " + machine.dropFirst("iPad".count) }
        return machine
    }

    /// ProductType → 监管型号（Axxxx）。设备不直接返回，用常见机型表兜底；
    /// 查不到就不显示（不编造）。
    static let regulatoryModel: [String: String] = [
        "iPhone15,4": "A2846", "iPhone15,5": "A2847",
        "iPhone16,1": "A2848", "iPhone16,2": "A2849",
        "iPhone14,7": "A2882", "iPhone14,8": "A2886",
        "iPhone15,2": "A2890", "iPhone15,3": "A2891",
        "iPhone14,5": "A2634", "iPhone14,4": "A2628",
        "iPhone14,2": "A2638", "iPhone14,3": "A2644",
        "iPhone13,2": "A2404", "iPhone13,1": "A2402",
        "iPhone13,3": "A2408", "iPhone13,4": "A2412",
        "iPhone12,1": "A2223", "iPhone12,3": "A2215", "iPhone12,5": "A2217",
        "iPhone17,3": "A3081", "iPhone17,4": "A3082",
        "iPhone17,1": "A3293", "iPhone17,2": "A3294",
        "iPhone17,5": "A3409",
    ]

    /// RegionInfo（如 "LL/A"）→ 销售地区名
    static let regions: [String: String] = [
        "LL/A": "美国", "CH/A": "中国大陆", "ZP/A": "中国香港", "ZA/A": "中国澳门",
        "TA/A": "中国台湾", "J/A": "日本", "KH/A": "韩国", "B/A": "英国",
        "D/A": "德国", "F/A": "法国", "X/A": "澳大利亚", "C/A": "加拿大",
        "HN/A": "印度", "RU/A": "俄罗斯", "BR/A": "巴西", "AA/A": "阿联酋",
    ]

    static func regionName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return regions[code]
    }

    /// v0.3.305：机身颜色代码（lockdown `DeviceColor`，设备侧只给数字）→ 中文名.
    ///
    /// ⚠️ **只收录有真机/爱思对照实证的映射**：iPhone15,4（`DeviceColor = 1`）爱思显示「黑色」。
    /// 其余代码（2/3/4…）没有实证，一律返回 nil 由 UI 显示原始代码，**不编造颜色表**
    /// （爱思的颜色名来自它自己的服务端，本地资源里没有该表）。
    static let deviceColors: [String: String] = [
        "1": "黑色",
    ]

    static func deviceColorName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return deviceColors[code]
    }

    /// 销售类型：苹果零售机型首字母 M=零售 / N=官换 / F=官翻 / P=定制
    static func salesType(_ modelNumber: String?) -> String? {
        guard let first = modelNumber?.uppercased().first else { return nil }
        switch first {
        case "M": return "零售机"
        case "N": return "官换机"
        case "F": return "官翻机"
        case "P": return "定制机"
        case "3": return "展示机"
        default: return nil
        }
    }

    /// 运营商：MCC+MNC → 运营商名（覆盖国内常见）
    static let carriers: [String: String] = [
        "46000": "中国移动", "46002": "中国移动", "46004": "中国移动",
        "46007": "中国移动", "46008": "中国移动",
        "46001": "中国联通", "46006": "中国联通", "46009": "中国联通",
        "46003": "中国电信", "46005": "中国电信", "46011": "中国电信",
        "46015": "中国广电",
    ]

    static func carrierName(mcc: String?, mnc: String?) -> String? {
        guard let mcc, !mcc.isEmpty, let mnc, !mnc.isEmpty else { return nil }
        let padded = mnc.count < 2 ? "0" + mnc : mnc
        return carriers[mcc + padded]
    }
}
