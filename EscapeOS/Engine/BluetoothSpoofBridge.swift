import Combine
import CoreLocation
import Foundation

/// 蓝牙链路 ↔ 现有虚拟定位的桥接层.
///
/// 只读 `SpoofSession`（status / lastError / pin），不修改其任何行为：
/// 面板不启用时本类不产生任何副作用.
@MainActor
final class BluetoothSpoofBridge {
    static let shared = BluetoothSpoofBridge()

    private let coordinator = BLECoordinator.shared
    private var cancellables = Set<AnyCancellable>()
    private var isAttached = false

    private init() {}

    /// 面板启用时挂上回调；重复调用安全.
    func attach() {
        guard !isAttached else { return }
        isAttached = true

        // B 机：收到 A 机下发的坐标 → 应用.
        coordinator.onCoordinate = { [weak self] coordinate in
            Task { @MainActor in self?.apply(coordinate) }
        }

        // A 机：收到 B 机的「请求下发」→ 把该坐标推回给 B（v0.3.540）.
        coordinator.onPushRequest = { [weak self] coordinate in
            Task { @MainActor in self?.push(coordinate) }
        }

        // A 机：图钉变化即下发.
        //
        // v0.3.540：**必须限定角色** —— B 机选图钉模式下，B 机自己每次
        // `teleport` 也会改 `SpoofSession.shared.pin`，若不判角色，B 机会把
        // 自己刚收到的坐标再下发一次（回环），A 机则会被自己收到的
        // 请求带回的 pin 变化反复触发。
        SpoofSession.shared.$pin
            .compactMap { $0 }
            .removeDuplicates { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
            .sink { [weak self] coordinate in
                guard let self, self.coordinator.currentRole == .broadcaster else { return }
                self.push(coordinate)
            }
            .store(in: &cancellables)

        // B 机：本机模拟状态变化即回报.
        SpoofSession.shared.$status
            .sink { [weak self] status in
                self?.report(status)
            }
            .store(in: &cancellables)

        // B 机：本机图钉变化 → 请求 A 机下发该坐标（v0.3.540 B 机选图钉）.
        SpoofSession.shared.$pin
            .compactMap { $0 }
            .removeDuplicates { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
            .sink { [weak self] coordinate in
                guard let self, self.coordinator.currentRole == .receiver else { return }
                self.request(coordinate)
            }
            .store(in: &cancellables)

        // 链路状态变化时补报一次（连接建立后让 A 机立即看到 B 机当前状态）.
        coordinator.$state
            .sink { [weak self] _ in
                guard let self else { return }
                self.report(SpoofSession.shared.status)
            }
            .store(in: &cancellables)
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        cancellables.removeAll()
        coordinator.onCoordinate = nil
        coordinator.onPushRequest = nil
    }

    /// 手动推当前图钉：按角色分流（v0.3.540）.
    ///
    /// A 机 = 下发；B 机 = 请求下发（走反向链路）.
    /// 两条链路终点都是「让 B 机应用这个坐标」，只是发起方与路径不同.
    func pushCurrentPin() -> Bool {
        guard let pin = SpoofSession.shared.pin else { return false }
        switch coordinator.currentRole {
        case .broadcaster: push(pin)
        case .receiver: request(pin)
        }
        return true
    }

    /// A 机下发：传地图坐标.
    private func push(_ coordinate: CLLocationCoordinate2D) {
        guard coordinator.isActive else { return }
        coordinator.send(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// B 机请求 A 机下发：传本机刚选的图钉坐标（v0.3.540）.
    private func request(_ coordinate: CLLocationCoordinate2D) {
        guard coordinator.isActive else { return }
        coordinator.requestPush(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// B 机应用：直接把收到的坐标交给 SpoofSession.
    ///
    /// 注意：`SpoofSession.apply` 内部已做 `ChinaCoordinateTransform.mapCoordinateToSystemCoordinate`，
    /// 这里必须传原始地图坐标，**不要再变换一次**（双重变换会把位置偏出去）.
    ///
    /// v0.3.540：改走 `applyRemoteCoordinate` —— 行为与 `teleport` 相同，
    /// 只是缺配对文件时给的是链路场景专用的提示语.
    private func apply(_ coordinate: CLLocationCoordinate2D) {
        guard coordinator.isActive else { return }
        SpoofSession.shared.applyRemoteCoordinate(coordinate)
    }

    /// B 机回报：把现有虚拟定位状态编成 2 字节上报.
    private func report(_ status: SpoofStatus) {
        guard coordinator.isActive else { return }
        let session = SpoofSession.shared
        coordinator.report(BluetoothStatusReport.from(status: status, hasError: session.lastError != nil))
    }
}
