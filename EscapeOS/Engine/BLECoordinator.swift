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

    private var peripheralManager: CBPeripheralManager?
    private var coordinateCharacteristic: CBMutableCharacteristic?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var pendingPayload: Data?
    private var lastPeerActivity: Date?
    private var lastPushAt: Date?
    private var watchdog: DispatchSourceTimer?

    private var centralManager: CBCentralManager?
    private var target: CBPeripheral?
    private var coordinateNotifyCharacteristic: CBCharacteristic?
    private var statusWriteCharacteristic: CBCharacteristic?
    /// B 机去重：与上次应用的坐标完全相同则丢弃.
    private var lastApplied: CLLocationCoordinate2D?
    /// B 机存活时间戳：任何收到的负载都刷新（含被去重丢弃的包）.
    private var lastReceivedAt: Date?
    private var lastScanStart = Date.distantPast

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

        // 兜底：没有活跃连接就不该停着广播（不依赖 didUnsubscribeFrom 单个回调）.
        guard let peripheral = peripheralManager,
              coordinateCharacteristic != nil,
              !peripheral.isAdvertising else { return }
        startAdvertisingLocked(peripheral)
    }

    private func receiverTickLocked() {
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
            CBAdvertisementDataLocalNameKey: BluetoothLink.localName
        ])
    }

    private func startScanLocked(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastScanStart)
        // 重扫最小间隔：连接反复失败时退避，避免高速重试空转.
        guard elapsed >= Self.minScanRestartInterval else {
            queue.asyncAfter(deadline: .now() + (Self.minScanRestartInterval - elapsed)) { [weak self] in
                guard let self, let central = self.centralManager, self.role == .receiver else { return }
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
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            fail("广播服务注册失败：\(error.localizedDescription)")
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
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        lastPeerActivity = Date()
        lastPushAt = Date()
        // 已建立连接：停止广播，之后只靠 notify 推送（降低掉线面）.
        peripheral.stopAdvertising()
        publish {
            self.peerName = String(central.identifier.uuidString.prefix(8))
            self.state = .connected
        }
        append("对端已订阅，停止广播")
        if let pending = pendingPayload { push(pending) }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BluetoothLink.coordinateCharacteristicUUID else { return }
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        guard subscribedCentrals.isEmpty else { return }
        lastPeerActivity = nil
        lastPushAt = nil
        publish { self.peerName = nil }
        updateState(.advertising)
        startAdvertisingLocked(peripheral)
        append("对端已断开，重新广播")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BluetoothLink.statusCharacteristicUUID,
               let value = request.value,
               let report = BluetoothStatusReport(data: value) {
                lastPeerActivity = Date()
                publish { self.lastReport = report }
                onReport?(report)
                append("收到回报：\(report.label)")
            }
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
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
        central.stopScan()
        target = peripheral
        peripheral.delegate = self
        updateState(.connecting)
        publish { self.peerName = peripheral.name ?? String(peripheral.identifier.uuidString.prefix(8)) }
        central.connect(peripheral, options: nil)
        append("发现对端，正在连接")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
