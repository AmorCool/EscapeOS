import Combine
import CoreBluetooth
import CoreLocation
import Foundation

/// 蓝牙位置模拟的传输层.
///
/// A 机 = `CBPeripheralManager`（持有「坐标」notify 特征与「状态」write 特征）；
/// B 机 = `CBCentralManager`（订阅坐标特征、写状态特征）.
/// 所有 CoreBluetooth 回调都在私有串行队列，`@Published` 一律回主线程更新.
final class BLECoordinator: NSObject, ObservableObject {
    static let shared = BLECoordinator()

    @Published private(set) var state: BluetoothLinkState = .off
    @Published private(set) var isActive = false
    @Published private(set) var peerName: String?
    @Published private(set) var lastSent: CLLocationCoordinate2D?
    @Published private(set) var lastReport: BluetoothStatusReport?
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []
    /// B 机：扫描到的附近设备（RSSI 降序）.
    @Published private(set) var nearby: [BluetoothNearbyPeer] = []
    /// B 机：当前已连接的对端 identifier（列表打勾用）.
    @Published private(set) var connectedPeerID: UUID?
    /// A 机：等待用户授权的连接请求（同一时刻只留一个）.
    @Published private(set) var pendingRequest: BluetoothConnectionRequest?
    /// A 机：本次会话是否已拒绝过连接（拒绝后停广播，需用户点「重新开始广播」）.
    @Published private(set) var hasDeniedPeers = false

    /// B 机收到 A 机下发的坐标（回调在 BLE 队列，调用方需自行切主线程）.
    var onCoordinate: ((CLLocationCoordinate2D) -> Void)?
    /// A 机收到 B 机的状态回报.
    var onReport: ((BluetoothStatusReport) -> Void)?

    private let queue = DispatchQueue(label: "com.escapeos.ble")
    private var role: BluetoothLinkRole = .broadcaster

    /// A 机看门狗：超过这个时长既没成功推送、也没收到 B 的回报就判定对端消失.
    private static let silentTimeout: TimeInterval = 25
    private static let watchdogTick: TimeInterval = 5
    /// A 机在连接期间周期性补发当前坐标，兼作链路活性探测.
    private static let resendInterval: TimeInterval = 8
    /// B 机重扫的最小间隔（失败退避）.
    private static let minScanRestartInterval: TimeInterval = 2
    /// B 机静默自愈：连上并订阅后超过这个时长收不到任何负载就重连（比 A 侧略大，让 A 先动）.
    private static let receiverSilentTimeout: TimeInterval = 30
    /// 相同日志的抑制窗口.
    private static let logSuppressWindow: TimeInterval = 3
    /// 附近设备超过这个时长没再出现就移除.
    private static let peerFreshWindow: TimeInterval = 12
    /// A 机连接请求的授权窗口：无人应答即自动拒绝（绝不默认放行）.
    private static let authorizationTimeout: TimeInterval = 20

    private var peripheralManager: CBPeripheralManager?
    private var coordinateCharacteristic: CBMutableCharacteristic?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var pendingPayload: Data?
    private var lastPeerActivity: Date?
    private var lastPushAt: Date?
    private var watchdog: DispatchSourceTimer?
    /// 待授权请求（BLE 队列上的真值，避免跨线程读 @Published）.
    private var pendingRequestValue: BluetoothConnectionRequest?
    private var pendingCentral: CBCentral?
    /// 本会话内被拒绝的 central（拒绝后不再询问、静默丢弃其数据）.
    private var deniedCentrals: Set<UUID> = []

    private var centralManager: CBCentralManager?
    private var target: CBPeripheral?
    private var coordinateNotifyCharacteristic: CBCharacteristic?
    private var statusWriteCharacteristic: CBCharacteristic?
    /// B 机去重：与上次应用的坐标完全相同则丢弃.
    private var lastApplied: CLLocationCoordinate2D?
    /// B 机存活时间戳：任何收到的负载都刷新（含被去重丢弃的包）.
    private var lastReceivedAt: Date?
    private var lastScanStart = Date.distantPast
    private var lastLogLine: String?
    private var lastLogAt: Date?
    /// B 机附近设备真值（identifier → peer）.
    private var peersLocked: [UUID: BluetoothNearbyPeer] = [:]
    /// B 机发现的 peripheral（供用户点选后连接）.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    private override init() {
        super.init()
    }

    // MARK: - 对外接口

    func start(role: BluetoothLinkRole) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            self.role = role
            self.lastApplied = nil
            switch role {
            case .broadcaster:
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue, options: nil)
            case .receiver:
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue, options: nil)
            }
            // 两种角色都要看门狗：A 侧防「对端消失后无法再被发现」，B 侧防「已连但收不到」.
            self.startWatchdogLocked()
            self.publish {
                self.isActive = true
                self.state = role == .broadcaster ? .advertising : .scanning
                self.lastError = nil
            }
            self.append("已启用：\(role.title)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            self.publish {
                self.isActive = false
                self.state = .off
                self.peerName = nil
                self.lastReport = nil
                self.lastSent = nil
            }
            self.append("已停用")
        }
    }

    /// A 机下发坐标（传地图坐标，转换由 SpoofSession 内部完成）.
    func send(latitude: Double, longitude: Double) {
        queue.async { [weak self] in
            self?.sendLocked(latitude: latitude, longitude: longitude)
        }
    }

    /// B 机回报状态.
    func report(_ report: BluetoothStatusReport) {
        queue.async { [weak self] in
            self?.reportLocked(report)
        }
    }

    func clearLog() {
        publish { self.log.removeAll() }
    }

    /// B 机：用户点选附近设备后连接（不再自动连第一个）.
    func connect(to id: UUID) {
        queue.async { [weak self] in
            guard let self, self.role == .receiver, self.target == nil else { return }
            guard let peripheral = self.discoveredPeripherals[id] else { return }
            guard self.centralManager?.state == .poweredOn else { return }
            self.centralManager?.stopScan()
            self.target = peripheral
            peripheral.delegate = self
            let name = self.peersLocked[id]?.displayName ?? String(id.uuidString.prefix(8))
            self.publish {
                self.connectedPeerID = id
                self.peerName = name
                self.state = .connecting
            }
            self.centralManager?.connect(peripheral, options: nil)
            self.append("正在连接 \(name)")
        }
    }

    /// B 机：手动重新扫描（不受退避限制）.
    func rescan() {
        queue.async { [weak self] in
            guard let self, self.role == .receiver, let central = self.centralManager else { return }
            self.lastScanStart = .distantPast
            self.startScanLocked(central)
            self.append("重新扫描附近设备")
        }
    }

    /// A 机：允许待授权请求.
    func approvePendingConnection() {
        queue.async { [weak self] in self?.approvePendingConnectionLocked() }
    }

    /// A 机：拒绝待授权请求（含超时自动拒绝）.
    func denyPendingConnection() {
        queue.async { [weak self] in self?.denyPendingConnectionLocked() }
    }

    /// A 机：用户点「重新开始广播」——忘掉拒绝记录并恢复广播（拒绝后唯一的解冻入口）.
    func resumeAdvertising() {
        queue.async { [weak self] in
            guard let self, self.role == .broadcaster, let peripheral = self.peripheralManager else { return }
            self.deniedCentrals.removeAll()
            self.subscribedCentrals.removeAll()
            self.lastPeerActivity = nil
            self.lastPushAt = nil
            self.coordinateCharacteristic = nil
            self.statusCharacteristic = nil
            self.publish { self.hasDeniedPeers = false }
            peripheral.stopAdvertising()
            peripheral.removeAllServices()
            // add 成功回调里会重新开始广播并把状态切回 .advertising.
            peripheral.add(self.makeServiceLocked())
            self.append("已重新开始广播")
        }
    }

    // MARK: - 队列内实现

    private func teardownLocked() {
        watchdog?.setEventHandler {}
        watchdog?.cancel()
        watchdog = nil
        lastPeerActivity = nil
        lastPushAt = nil
        lastApplied = nil
        lastReceivedAt = nil
        lastScanStart = .distantPast
        pendingRequestValue = nil
        pendingCentral = nil
        deniedCentrals.removeAll()
        peersLocked.removeAll()
        discoveredPeripherals.removeAll()

        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager?.delegate = nil
        peripheralManager = nil
        coordinateCharacteristic = nil
        statusCharacteristic = nil
        subscribedCentrals.removeAll()
        pendingPayload = nil

        centralManager?.stopScan()
        if let connecting = target { centralManager?.cancelPeripheralConnection(connecting) }
        centralManager?.delegate = nil
        centralManager = nil
        target = nil
        coordinateNotifyCharacteristic = nil
        statusWriteCharacteristic = nil

        publish {
            self.nearby = []
            self.connectedPeerID = nil
            self.pendingRequest = nil
            self.hasDeniedPeers = false
        }
    }

    /// A 机看门狗：负责「对端消失 → 重新广播」「无连接却未广播 → 补广播」「连接期补发坐标」；
    /// B 机看门狗：负责「已连但长时间收不到负载 → 重连」.
    private func startWatchdogLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.watchdogTick,
            repeating: Self.watchdogTick,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in self?.watchdogTickLocked() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTickLocked() {
        switch role {
        case .broadcaster: broadcasterTickLocked()
        case .receiver: receiverTickLocked()
        }
    }

    private func broadcasterTickLocked() {
        let now = Date()

        // 无人应答即自动拒绝：面板没打开时没人点按钮，绝不能默认放行.
        if let request = pendingRequestValue,
           now.timeIntervalSince(request.receivedAt) > Self.authorizationTimeout {
            denyPendingConnectionLocked()
        }

        if !subscribedCentrals.isEmpty {
            // 没有待发坐标时不判定失联：无流量可等，避免误把「空闲但对端正常」当成对端消失.
            guard pendingPayload != nil else { return }
            if let last = lastPeerActivity, now.timeIntervalSince(last) > Self.silentTimeout {
                subscribedCentrals.removeAll()
                lastPeerActivity = nil
                lastPushAt = nil
                publish {
                    self.peerName = nil
                    self.state = .advertising
                }
                append("对端失联，已重新开始广播")
                if let peripheral = peripheralManager { startAdvertisingLocked(peripheral) }
                return
            }
            if let payload = pendingPayload,
               let lastPush = lastPushAt,
               now.timeIntervalSince(lastPush) >= Self.resendInterval {
                push(payload)
            }
            return
        }

        // 兜底：没有活跃连接就不该停着广播（不依赖 didUnsubscribeFrom 单个回调）；
        // 但拒绝记忆生效期间绝不自作主张恢复广播，必须等用户点「重新开始广播」.
        guard deniedCentrals.isEmpty,
              let peripheral = peripheralManager,
              coordinateCharacteristic != nil,
              !peripheral.isAdvertising else { return }
        startAdvertisingLocked(peripheral)
    }

    private func receiverTickLocked() {
        pruneNearbyLocked()
        // 只在「已连上且订阅成功」之后计时；lastReceivedAt 由每次收到的负载刷新（含被去重丢弃的包）.
        guard target != nil, coordinateNotifyCharacteristic != nil else { return }
        guard let last = lastReceivedAt else { return }
        guard Date().timeIntervalSince(last) > Self.receiverSilentTimeout else { return }

        // 重新计时：重连不成时按同一周期再试，不刷屏.
        self.lastReceivedAt = Date()
        append("长时间未收到坐标，已重新连接")
        if let peripheral = target { centralManager?.cancelPeripheralConnection(peripheral) }
        if let central = centralManager { startScanLocked(central) }
    }

    private func sendLocked(latitude: Double, longitude: Double) {
        guard role == .broadcaster,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else { return }
        let payload = BluetoothLocationPayload(latitude: latitude, longitude: longitude).encoded()
        pendingPayload = payload
        push(payload)
        let delivered = !subscribedCentrals.isEmpty
        publish {
            self.lastSent = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if delivered { self.state = .synced }
        }
    }

    @discardableResult
    private func push(_ payload: Data) -> Bool {
        guard let peripheral = peripheralManager,
              let characteristic = coordinateCharacteristic,
              !subscribedCentrals.isEmpty else { return false }
        // 队列已满时 updateValue 返回 false，等 peripheralManagerIsReady 回调再补发.
        let accepted = peripheral.updateValue(payload, for: characteristic, onSubscribedCentrals: subscribedCentrals)
        if accepted {
            lastPushAt = Date()
            lastPeerActivity = Date()
        }
        return accepted
    }

    private func reportLocked(_ report: BluetoothStatusReport) {
        guard role == .receiver,
              let peripheral = target,
              let characteristic = statusWriteCharacteristic,
              peripheral.state == .connected else { return }
        peripheral.writeValue(report.encoded(), for: characteristic, type: .withResponse)
    }

    private func startAdvertisingLocked(_ peripheral: CBPeripheralManager) {
        guard !peripheral.isAdvertising else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BluetoothLink.serviceUUID],
            CBAdvertisementDataLocalNameKey: BluetoothLink.broadcastName(for: role)
        ])
    }

    @discardableResult
    private func makeServiceLocked() -> CBMutableService {
        let coordinate = CBMutableCharacteristic(
            type: BluetoothLink.coordinateCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let status = CBMutableCharacteristic(
            type: BluetoothLink.statusCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: BluetoothLink.serviceUUID, primary: true)
        service.characteristics = [coordinate, status]
        coordinateCharacteristic = coordinate
        statusCharacteristic = status
        return service
    }

    private func setPendingRequestLocked(_ request: BluetoothConnectionRequest?) {
        pendingRequestValue = request
        publish { self.pendingRequest = request }
    }

    private func approvePendingConnectionLocked() {
        guard let request = pendingRequestValue, let central = pendingCentral else { return }
        setPendingRequestLocked(nil)
        pendingCentral = nil
        deniedCentrals.remove(request.centralIdentifier)
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        lastPeerActivity = Date()
        lastPushAt = Date()
        publish {
            self.peerName = request.displayName
            self.state = .connected
        }
        append("已允许 \(request.displayName) 连接")
        if let pending = pendingPayload { push(pending) }
    }

    /// 拒绝（手动 / 超时共用）：记住该 central、拆服务踢掉对端、不重新广播.
    /// 拆服务是 peripheral 侧唯一的「拒绝连接」手段；不重广播才不会形成「重连→重问」循环.
    private func denyPendingConnectionLocked() {
        guard let request = pendingRequestValue else { return }
        setPendingRequestLocked(nil)
        pendingCentral = nil
        deniedCentrals.insert(request.centralIdentifier)
        subscribedCentrals.removeAll()
        lastPeerActivity = nil
        lastPushAt = nil
        coordinateCharacteristic = nil
        statusCharacteristic = nil
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        publish {
            self.peerName = nil
            self.hasDeniedPeers = true
            self.state = .suspended
        }
        append("已拒绝 \(request.displayName)（本次会话不再询问）")
    }

    private func publishNearbyLocked() {
        let sorted = peersLocked.values.sorted { $0.rssi > $1.rssi }
        publish { self.nearby = sorted }
    }

    private func pruneNearbyLocked() {
        let now = Date()
        let kept = peersLocked.filter { now.timeIntervalSince($0.value.lastSeen) < Self.peerFreshWindow }
        guard kept.count != peersLocked.count else { return }
        peersLocked = kept
        publishNearbyLocked()
    }

    private func startScanLocked(_ central: CBCentralManager) {
        guard central.state == .poweredOn, target == nil else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastScanStart)
        // 重扫最小间隔：连接反复失败时退避，避免高速重试空转.
        guard elapsed >= Self.minScanRestartInterval else {
            queue.asyncAfter(deadline: .now() + (Self.minScanRestartInterval - elapsed)) { [weak self] in
                guard let self, self.role == .receiver, self.target == nil,
                      let central = self.centralManager else { return }
                self.startScanLocked(central)
            }
            return
        }
        lastScanStart = now
        // 无条件重扫：isScanning 在 stopScan 后异步翻转，按它判断会让重连路径卡死.
        central.stopScan()
        central.scanForPeripherals(withServices: [BluetoothLink.serviceUUID], options: nil)
        publish { self.state = .scanning }
    }

    // MARK: - 主线程发布

    private func publish(_ changes: @escaping () -> Void) {
        if Thread.isMainThread {
            changes()
        } else {
            DispatchQueue.main.async(execute: changes)
        }
    }

    private func updateState(_ newState: BluetoothLinkState) {
        publish { self.state = newState }
    }

    private func fail(_ message: String) {
        publish {
            self.lastError = message
            self.state = .off
        }
        append(message)
    }

    private func append(_ line: String) {
        let now = Date()
        // 很短窗口内的同一条日志只留一条（append 全在 BLE 队列调用，无需额外同步）.
        if let previous = lastLogLine, previous == line,
           let previousAt = lastLogAt,
           now.timeIntervalSince(previousAt) < Self.logSuppressWindow {
            return
        }
        lastLogLine = line
        lastLogAt = now
        let stamped = "\(Self.timeString()) \(line)"
        let run = {
            self.log.insert(stamped, at: 0)
            if self.log.count > 60 { self.log.removeLast(self.log.count - 60) }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

extension BLECoordinator: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            fail("蓝牙不可用：\(peripheral.state.linkLabel)")
            return
        }
        peripheral.removeAllServices()
        peripheral.add(makeServiceLocked())
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            fail("广播服务注册失败：\(error.localizedDescription)")
            return
        }
        // 拒绝记忆生效期间只注册服务、不广播.
        guard deniedCentrals.isEmpty else {
            publish { self.state = .suspended }
            return
        }
        startAdvertisingLocked(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            fail("广播启动失败：\(error.localizedDescription)")
            return
        }
        updateState(.advertising)
        append("开始广播")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID else { return }
        // 已拒绝过的 central 不再询问、也不放行（拒绝记忆生效期间静默忽略）.
        guard !deniedCentrals.contains(central.identifier) else { return }
        // 已建立连接：停止广播，之后只靠 notify 推送（降低掉线面）.
        peripheral.stopAdvertising()
        // 不直接放行：先挂起，交由 UI 询问用户（同一时刻只留一个待处理请求）.
        pendingCentral = central
        setPendingRequestLocked(BluetoothConnectionRequest(
            centralIdentifier: central.identifier,
            displayName: BluetoothLink.displayName(for: .receiver),
            receivedAt: Date()
        ))
        append("收到连接请求，等待允许")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID else { return }
        if let pending = pendingRequestValue, pending.centralIdentifier == central.identifier {
            setPendingRequestLocked(nil)
            pendingCentral = nil
        }
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        guard subscribedCentrals.isEmpty else { return }
        lastPeerActivity = nil
        lastPushAt = nil
        publish { self.peerName = nil }
        // 拒绝记忆生效期间不回弹广播，保持「已停止广播」.
        guard deniedCentrals.isEmpty else {
            publish { self.state = .suspended }
            return
        }
        updateState(.advertising)
        startAdvertisingLocked(peripheral)
        append("对端已断开，重新广播")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            // 未授权的 central 一律丢弃（拒绝连接只能靠不给数据）.
            let authorized = subscribedCentrals.contains { $0.identifier == request.central.identifier }
            if authorized,
               request.characteristic.uuid == BluetoothLink.statusCharacteristicUUID,
               let value = request.value,
               let report = BluetoothStatusReport(data: value) {
                lastPeerActivity = Date()
                publish { self.lastReport = report }
                onReport?(report)
                append("收到回报：\(report.label)")
            }
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: authorized ? .success : .notPermitted)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let pending = pendingPayload else { return }
        push(pending)
    }
}

extension BLECoordinator: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            fail("蓝牙不可用：\(central.state.linkLabel)")
            return
        }
        startScanLocked(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard target == nil else { return }
        // 只累积列表，不自动连接：等用户在「附近设备」里点选.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        discoveredPeripherals[peripheral.identifier] = peripheral
        peersLocked[peripheral.identifier] = BluetoothNearbyPeer(
            id: peripheral.identifier,
            name: advertisedName ?? peripheral.name ?? "",
            role: BluetoothLink.role(fromBroadcastName: advertisedName)
                ?? BluetoothLink.role(fromBroadcastName: peripheral.name),
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        pruneNearbyLocked()
        publishNearbyLocked()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        publish { self.connectedPeerID = peripheral.identifier }
        updateState(.connected)
        append("已连接")
        peripheral.discoverServices([BluetoothLink.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        target = nil
        publish { self.connectedPeerID = nil }
        append("连接失败，重新扫描")
        startScanLocked(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        coordinateNotifyCharacteristic = nil
        statusWriteCharacteristic = nil
        target = nil
        // 断线后重新接到同一坐标也要重新应用（旧会话已失效），故清空去重记录与静默计时.
        lastApplied = nil
        lastReceivedAt = nil
        publish { self.connectedPeerID = nil }
        append("连接断开，重新扫描")
        startScanLocked(central)
    }
}

extension BLECoordinator: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothLink.serviceUUID }) else {
            return
        }
        peripheral.discoverCharacteristics(
            [BluetoothLink.coordinateCharacteristicUUID, BluetoothLink.statusCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID {
                coordinateNotifyCharacteristic = characteristic
                // 从「请求订阅」起就计时，避免订阅回调不到时静默卡死.
                lastReceivedAt = Date()
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == BluetoothLink.statusCharacteristicUUID {
                statusWriteCharacteristic = characteristic
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID else { return }
        if characteristic.isNotifying {
            // 订阅成功即开始计静默窗口.
            lastReceivedAt = Date()
            updateState(.connected)
            append("已订阅坐标推送")
        } else {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID,
              let data = characteristic.value,
              let coordinate = BluetoothLocationPayload.coordinate(from: data) else { return }
        // 先刷存活时间戳：去重只决定「要不要重新应用坐标」，不参与「链路是否存活」的判定.
        lastReceivedAt = Date()
        if let last = lastApplied,
           last.latitude == coordinate.latitude,
           last.longitude == coordinate.longitude {
            return
        }
        lastApplied = coordinate
        updateState(.synced)
        append("收到新坐标，已应用")
        onCoordinate?(coordinate)
    }
}

private extension CBManagerState {
    var linkLabel: String {
        switch self {
        case .poweredOff: return "已关闭"
        case .unauthorized: return "未授权"
        case .unsupported: return "设备不支持"
        case .resetting: return "正在重置"
        case .unknown: return "状态未知"
        case .poweredOn: return "正常"
        @unknown default: return "状态未知"
        }
    }
}
