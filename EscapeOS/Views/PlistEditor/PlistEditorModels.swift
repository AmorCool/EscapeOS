import Foundation

/// plist 里一个条目的类型。
///
/// 移植自 Erosion 的 `PlistItemType`。`label` 保留 Xcode/plist 的标准英文术语
/// 便于对照，`displayName` 是界面上显示的中文。
enum PlistItemType: String, CaseIterable, Identifiable {
    case string
    case int
    case double
    case bool
    case data
    case date
    case dict
    case array
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .string: return "String"
        case .int: return "Integer"
        case .double: return "Double"
        case .bool: return "Boolean"
        case .data: return "Data"
        case .date: return "Date"
        case .dict: return "Dictionary"
        case .array: return "Array"
        case .unknown: return "Unknown"
        }
    }

    var displayName: String {
        switch self {
        case .string: return "字符串"
        case .int: return "整数"
        case .double: return "小数"
        case .bool: return "布尔"
        case .data: return "数据"
        case .date: return "日期"
        case .dict: return "字典"
        case .array: return "数组"
        case .unknown: return "未知"
        }
    }

    /// 是否是有子条目的容器类型（字典 / 数组）。
    var isContainer: Bool {
        self == .dict || self == .array
    }
}

/// plist 树上的一个节点。
///
/// 移植自 Erosion 的 `PlistItem`：除了保留原始值 `rawVal`（写回时 Data 类型要靠它），
/// 另存一份可编辑的 `stringVal` / `boolVal`，容器类型则递归存 `dictVal`。
/// 字典与数组的子条目都放在 `dictVal` 里，靠 `type` 区分序列化方式。
struct PlistItem: Identifiable {
    var id = UUID()
    var key: String
    var rawVal: Any?
    var type: PlistItemType = .unknown
    /// 数组元素的序号（字典条目为 nil）。
    var index: Int?
    var isExpanded: Bool

    var stringVal: String = ""
    var boolVal: Bool = false
    var dictVal: [PlistItem] = []

    init(key: String, value: Any, isExpanded: Bool = false) {
        self.key = key
        self.rawVal = value
        self.isExpanded = isExpanded
        self.type = Self.detectType(of: value)

        switch value {
        case let v as String:
            stringVal = v
        case let v as Int:
            stringVal = String(v)
        case let v as Double:
            stringVal = String(v)
        case let v as Bool:
            boolVal = v
        case let v as Date:
            stringVal = v.description
        case let v as Data:
            stringVal = v.base64EncodedString()
        case let v as [String: Any]:
            dictVal = v.map { PlistItem(key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            stringVal = v.description
        case let v as [Any]:
            dictVal = v.enumerated().map { index, value in
                var item = PlistItem(key: "Item \(index)", value: value)
                item.index = index
                return item
            }
            stringVal = v.description
        default:
            stringVal = "\(value)"
        }
    }

    /// 序列化回 plist 能接受的原始值。
    func rawValue() -> Any {
        switch type {
        case .string:
            return stringVal
        case .int:
            return Int(stringVal) ?? 0
        case .double:
            return Double(stringVal) ?? 0
        case .bool:
            return boolVal
        case .data:
            // Data 不做文本往返（base64 会改变二进制 plist 的语义），
            // 保留读进来时的原始值。
            return rawVal ?? Data()
        case .date:
            return rawVal ?? stringVal
        case .dict:
            var dictionary = [String: Any]()
            for item in dictVal { dictionary[item.key] = item.rawValue() }
            return dictionary
        case .array:
            return dictVal.map { $0.rawValue() }
        case .unknown:
            return rawVal ?? stringVal
        }
    }

    private static func detectType(of value: Any) -> PlistItemType {
        switch value {
        case is String: return .string
        case is Int: return .int
        case is Double: return .double
        case is Bool: return .bool
        case is Date: return .date
        case is Data: return .data
        case is [String: Any]: return .dict
        case is [Any]: return .array
        default: return .unknown
        }
    }
}
