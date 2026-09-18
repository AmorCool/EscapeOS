import CoreBluetooth
import CoreLocation
import Foundation

/// 蓝牙位置模拟的链路角色.
///
/// - `broadcaster`：A 机（模拟终端），广播服务并把坐标推给对端；
/// - `receiver`：B 机（信号端），连接 A 机、收坐标并交给虚拟定位应用.
enum BluetoothLinkRole: String, CaseIterable, Identifiable {
    case broadcaster
    case receiver

    var id: String { rawValue }

    /// 选择器用的完整名.
    var title: String {
        switch self {
        case .broadcaster: return "模拟终端（下发）"
        case .receiver: return "信号端（应用）"
        }
    }

    /// 附近设备列表等窄位置用的短名.
    var shortTitle: String {
        switch self {
        case .broadcaster: return "模拟终端"
        case .receiver: return "信号端"
        }
    }
}

/// 面板状态机（7 态）.错误原因单独放 `lastError`，不占状态位.
enum BluetoothLinkState: Equatable {
    case off
    case advertising
    case scanning
    case connecting
    case connected
    case synced
    /// A 机拒绝过连接：已停广播，等用户点「重新开始广播」.
    case suspended

    var label: String {
        switch self {
        case .off: return "未启用"
        case .advertising: return "广播中，等待对端"
        case .scanning: return "扫描中，等待对端"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .synced: return "已同步"
        case .suspended: return "已停止广播"
        }
    }
}

/// 链路常量（UUID 双方一致；广播名按角色区分）.
enum BluetoothLink {
    /// Swift 6 并发检查：`CBUUID` 非 Sendable，但这三个都是**构造后永不修改的常量**
    /// （只用于广播/订阅时的匹配比较），跨线程只读访问安全。
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "E5C0A100-1B2F-4E6A-9A11-0E50F1A1B001")
    /// A 机 notify、B 机订阅：坐标下行（同上：不可变常量）.
    nonisolated(unsafe) static let coordinateCharacteristicUUID = CBUUID(string: "E5C0A101-1B2F-4E6A-9A11-0E50F1A1B001")
    /// B 机 write、A 机接收：状态回报上行（同上：不可变常量）.
    nonisolated(unsafe) static let statusCharacteristicUUID = CBUUID(string: "E5C0A102-1B2F-4E6A-9A11-0E50F1A1B001")

    /// 广播名：广播包用户可用数据只有 28 字节，128-bit serviceUUID 已占 18，名字必须极短.
    static func broadcastName(for role: BluetoothLinkRole) -> String {
        switch role {
        case .broadcaster: return "ES-T"
        case .receiver: return "ES-S"
        }
    }

    /// UI 展示名.
    static func displayName(for role: BluetoothLinkRole?) -> String {
        switch role {
        case .broadcaster: return "EscapeSpace（模拟终端）"
        case .receiver: return "EscapeSpace（信号端）"
        case nil: return "未知设备"
        }
    }

    /// 从广播名反解角色：只作附加确认（广播名装不下时会被系统丢弃，不能依赖它）.
    static func role(fromBroadcastName name: String?) -> BluetoothLinkRole? {
        guard let name else { return nil }
        if name.hasSuffix("-T") { return .broadcaster }
        if name.hasSuffix("-S") { return .receiver }
        return nil
    }
}

/// 扫描到的附近设备（按 peripheral identifier 去重累积）.
struct BluetoothNearbyPeer: Identifiable, Equatable {
    let id: UUID
    /// 广播名原始值（可能为空，仅作排查参考）.
    var name: String
    var role: BluetoothLinkRole?
    var rssi: Int
    var lastSeen: Date

    /// 只有「模拟终端」在广播，所以扫到的对端必然是终端；解析不到广播名也按终端渲染，
    /// 不允许退化成「未知设备」.
    var displayName: String {
        BluetoothLink.displayName(for: role ?? .broadcaster)
    }

    /// 角色文案（窄位置用短名）.
    var roleText: String { (role ?? .broadcaster).shortTitle }
}

/// A 机收到的待授权连接请求.
struct BluetoothConnectionRequest: Identifiable, Equatable {
    let centralIdentifier: UUID
    let displayName: String
    let receivedAt: Date

    var id: UUID { centralIdentifier }
}

/// 坐标载荷 v1：1 字节版本 + 2 × Double(纬度, 经度)，小端，共 17 字节.
struct BluetoothLocationPayload {
    static let version: UInt8 = 1
    static let byteCount = 17

    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.byteCount,
              bytes[0] == Self.version,
              let latitude = Self.readDouble(bytes, at: 1),
              let longitude = Self.readDouble(bytes, at: 9) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    func encoded() -> Data {
        var data = Data([Self.version])
        Self.append(latitude, to: &data)
        Self.append(longitude, to: &data)
        return data
    }

    static func coordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard let payload = BluetoothLocationPayload(data: data) else { return nil }
        return CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
    }

    private static func append(_ value: Double, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func readDouble(_ bytes: [UInt8], at offset: Int) -> Double? {
        guard offset >= 0, bytes.count >= offset + 8 else { return nil }
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(bytes[offset + index]) << UInt64(8 * index)
        }
        return Double(bitPattern: bits)
    }
}

/// B→A 回报：1 字节状态码 + 1 字节错误码（0 = 无错误），共 2 字节.
struct BluetoothStatusReport: Equatable {
    static let byteCount = 2

    let code: UInt8
    let error: UInt8

    init(code: UInt8, error: UInt8) {
        self.code = code
        self.error = error
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.byteCount else { return nil }
        self.code = bytes[0]
        self.error = bytes[1]
    }

    func encoded() -> Data { Data([code, error]) }

    var label: String {
        let base: String
        switch code {
        case 0: base = "未模拟定位"
        case 1: base = "正在连接"
        case 2: base = "正在模拟定位"
        case 3: base = "正在重新连接"
        case 4: base = "连接中断"
        default: base = "未知状态"
        }
        return error == 0 ? base : "\(base)（对端报错）"
    }

    static func from(status: SpoofStatus, hasError: Bool) -> BluetoothStatusReport {
        let code: UInt8
        switch status {
        case .idle: code = 0
        case .connecting: code = 1
        case .active: code = 2
        case .reconnecting: code = 3
        case .dropped: code = 4
        }
        return BluetoothStatusReport(code: code, error: hasError ? 1 : 0)
    }
}
