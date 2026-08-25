//
//  BackgroundLocationManager.swift
//  EscapeSpace
//
//  后台位置更新保活。移植自 StikPair / StikDebug：
//  通过持续请求位置更新（精度极低、距离过滤最大），
//  使应用在后台/锁屏时仍被视为「正在使用位置服务」，
//  从而延缓 Bonjour 注册被系统 SRP sweeper 回收。
//

import CoreLocation

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activityCount = 0

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    /// 持久开启（无线配对期间调用）。
    func start() {
        isRunning = true
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// 持久关闭（配对结束 / sheet 关闭时调用）。
    func stop() {
        isRunning = false
        locationManager.stopUpdatingLocation()
    }

    /// 临时请求开启（计数器模式）。
    func requestStart() {
        activityCount += 1
        if activityCount == 1, UserDefaults.standard.bool(forKey: "keepAliveLocation") {
            start()
        }
    }

    /// 临时请求关闭。
    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        if activityCount == 0 {
            stop()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 室内无 GPS 等导致定位失败是正常的；
        // 只要 manager 在运行即可达到保活目的，不必真正 fix 到位置。
    }
}
