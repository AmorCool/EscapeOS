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

/// B→A 回报：1 字节消息类型 + 负载.
///
/// ## v0.3.540：上行通道从「只报状态」扩成「带类型的消息」
///
/// 背景：用户拍板把选图钉的位置改到 **B 机**（符合直觉 —— 谁要用谁选）。
/// 这需要一条 **B→A 的反向请求**：B 机放图钉后告诉 A 机「请把这个坐标下发给我」。
///
/// 设计上**不新增特征**，直接复用既有的「状态」write 特征（`E5C0A102-…`）：
/// 所有上行消息共用它，靠**首字节的类型标签**区分。
///
/// ## 注意： 类型标签为什么从 0x80 起（不能从 0/1 起）
///
/// 历史线格式里，状态消息的首字节是**状态码 0~4**（idle / connecting / active /
/// reconnecting / dropped）。若把 `requestPush` 的标签取成 `1`，就会和
/// 「正在连接」这个状态码**撞车**，A 机无法区分两者。
/// 所以新类型的标签一律取 **`0x80` 以上**（状态码永远 ≤ 4），
/// A 机读到 `≥ 0x80` 就当新消息处理，读到 `≤ 4` 就当老格式的状态回报 —— 天然不冲突。
///
/// ## 线格式
/// ```
/// status       ：[code(0~4)][error]                     共 2 字节（与 v0.3.539 一致）
/// requestPush  ：[0x80][纬度 8 字节小端][经度 8 字节小端]  共 17 字节
/// ```
struct BluetoothUplinkMessage: Equatable {
    /// 上行消息类型标签.
    ///
    /// 取值从 `0x80` 起 —— 见类型注释里「为什么不能从 0/1 起」.
    enum Kind: UInt8 {
        /// B 机请求 A 机下发指定坐标（新协议）.
        case requestPush = 0x80
    }

    /// `requestPush` 的线上字节数：1 + 8 + 8.
    static let requestPushByteCount = 17

    let kind: Kind
    /// B 机当前选的图钉坐标.
    let requestedCoordinate: CLLocationCoordinate2D

    /// 手写 `==`：`CLLocationCoordinate2D` 是 C 结构体，**不满足 `Equatable`**，
    /// 所以编译器无法合成 `Equatable` 一致性（v0.3.540 CI 实测报错：
    /// `stored property type 'CLLocationCoordinate2D' does not conform to protocol 'Equatable'`）。
    /// 按经纬度逐字段比较即可 —— 浮点用 `==` 是有意的：这里比的是「同一个坐标原样往返」，
    /// 不涉及计算，位级相等才说明编码/解码没丢精度。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.requestedCoordinate.latitude == rhs.requestedCoordinate.latitude
            && lhs.requestedCoordinate.longitude == rhs.requestedCoordinate.longitude
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        // 首字节 ≥ 0x80 才是新消息；否则是状态回报，不由本类型解析.
        guard let first = bytes.first,
              first >= 0x80,
              let kind = Kind(rawValue: first) else { return nil }
        switch kind {
        case .requestPush:
            guard bytes.count == Self.requestPushByteCount,
                  let lat = Self.readDouble(bytes, at: 1),
                  let lon = Self.readDouble(bytes, at: 9) else { return nil }
            self.kind = .requestPush
            self.requestedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    init(requestedCoordinate: CLLocationCoordinate2D) {
        self.kind = .requestPush
        self.requestedCoordinate = requestedCoordinate
    }

    func encoded() -> Data {
        var data = Data([kind.rawValue])
        Self.append(requestedCoordinate.latitude, to: &data)
        Self.append(requestedCoordinate.longitude, to: &data)
        return data
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
