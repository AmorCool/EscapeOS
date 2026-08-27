import CoreLocation
import Foundation

/// 轻量后台定位（移植自 locus-ZH）：虚拟定位激活期间保持轻量 GPS 会话，
/// 让地图定位点 / 「回到真实位置」可用，同时借助 location 后台模式延长
/// 进程存活时间。
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var lastKnownLocation: CLLocation?

    var lastKnownCoordinate: CLLocationCoordinate2D? {
        lastKnownLocation?.coordinate
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .restricted, .denied:
            return
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            return
        }
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()
        let candidates = locations.filter { location in
            location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy <= 200 &&
            abs(location.timestamp.timeIntervalSince(now)) <= 15
        }
        guard let best = candidates.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else { return }

        if let current = lastKnownLocation,
           current.timestamp > best.timestamp,
           current.horizontalAccuracy <= best.horizontalAccuracy {
            return
        }
        lastKnownLocation = best
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位授权未就绪或 GPS 未稳定时的瞬时失败可忽略。
    }
}
