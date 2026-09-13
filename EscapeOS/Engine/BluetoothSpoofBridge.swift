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

        coordinator.onCoordinate = { [weak self] coordinate in
            Task { @MainActor in self?.apply(coordinate) }
        }

        // A 机：图钉变化即下发.
        SpoofSession.shared.$pin
            .compactMap { $0 }
            .removeDuplicates { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
            .sink { [weak self] coordinate in
                self?.push(coordinate)
            }
            .store(in: &cancellables)

        // B 机：本机模拟状态变化即回报.
        SpoofSession.shared.$status
            .sink { [weak self] status in
                self?.report(status)
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
    }

    /// 手动下发当前图钉.
    func pushCurrentPin() -> Bool {
        guard let pin = SpoofSession.shared.pin else { return false }
        push(pin)
        return true
    }

    /// A 机下发：传地图坐标.
    private func push(_ coordinate: CLLocationCoordinate2D) {
        guard coordinator.isActive else { return }
        coordinator.send(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// B 机应用：直接把收到的坐标交给 teleport.
    ///
    /// 注意：`SpoofSession.apply` 内部已做 `ChinaCoordinateTransform.mapCoordinateToSystemCoordinate`，
    /// 这里必须传原始地图坐标，**不要再变换一次**（双重变换会把位置偏出去）.
    private func apply(_ coordinate: CLLocationCoordinate2D) {
        guard coordinator.isActive else { return }
        SpoofSession.shared.teleport(to: coordinate)
    }

    /// B 机回报：把现有虚拟定位状态编成 2 字节上报.
    private func report(_ status: SpoofStatus) {
        guard coordinator.isActive else { return }
        let session = SpoofSession.shared
        coordinator.report(BluetoothStatusReport.from(status: status, hasError: session.lastError != nil))
    }
}
