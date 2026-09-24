import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

/// 移动方式（轨迹/摇杆速度基准）.
enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "步行"
        case .run: return "跑步"
        case .cycle: return "骑行"
        case .drive: return "驾车"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// 基础速度（米/秒），叠加自然波动.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "未模拟定位"
        case .connecting: return "正在连接…"
        case .active: return "正在模拟定位"
        case .reconnecting: return "正在重新连接…"
        case .dropped: return "连接中断"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// 虚拟定位会话（移植自 locus-ZH）.
///
/// **全局单例**：从虚拟定位页面返回后会话仍存活，模拟注入、
/// 8 秒重发 / 12 秒心跳定时器继续运行——「离开界面也保持运行」.
/// 进程退后台则由 KeepAliveManager（静音音频保活）+ 后台定位延续.
@MainActor
final class SpoofSession: ObservableObject {
    static let shared = SpoofSession()

    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    /// v0.3.251：最近一次清除后是否成功 SIGKILL 了 locationd（nil = 未执行过清除）
    @Published var locationdKilled: Bool?
    @Published var isBusy = false
    @Published var joystickActive = false
    @Published private(set) var routeActive = false
    @Published private(set) var routePaused = false
    @Published private(set) var routeProgress = 0.0
    @Published private(set) var routeLap = 0
    @Published var speedMultiplier: Double = 1.0 {
        didSet { UserDefaults.standard.set(speedMultiplier, forKey: "escape.speedMultiplier") }
    }
    @Published var routeLoopEnabled = false {
        didSet { UserDefaults.standard.set(routeLoopEnabled, forKey: "escape.routeLoopEnabled") }
    }
    /// 增强守护：ON 档缩短重发/健康检查间隔，并在回前台、检出会话被回收时立刻重发.
    /// OFF 档与历史行为完全一致（8s 重发 / 12s 健康检查，不写守护日志）.
    @Published var locationGuard = false {
        didSet {
            guard locationGuard != oldValue else { return }
            UserDefaults.standard.set(locationGuard, forKey: "escape.locationGuard")
            LoginLogger.shared.log("增强守护：\(locationGuard ? "开启" : "关闭")")
            // 已在模拟中则立刻切档，不必等本次模拟结束.
            if isSpoofing {
                startResend()
                startHealth()
            }
        }
    }

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var activeRoute: [CLLocationCoordinate2D] = []
    private var routeGeneration = UUID()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    /// 增强守护的累计重发次数与「疑似复位」命中次数（重发前链路已被回收）.
    private var guardResendTotal = 0
    private var guardResetHits = 0

    private let favoritesKey = "escape.favorites"
    private let recentsKey = "escape.recents"

    /// 增强守护重发的来源（写日志用）.
    private enum GuardTrigger: String {
        case timer = "定时"
        case health = "健康检查"
        case foreground = "回前台"
        case manual = "手动"
    }

    /// 重发间隔：ON 档 3s，OFF 档保持 8s.
    private var resendInterval: TimeInterval { locationGuard ? 3 : 8 }
    /// 健康检查间隔：ON 档 5s，OFF 档保持 12s.
    private var healthInterval: TimeInterval { locationGuard ? 5 : 12 }

    private init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        let storedSpeed = UserDefaults.standard.double(forKey: "escape.speedMultiplier")
        speedMultiplier = storedSpeed > 0 ? min(4.0, max(0.25, storedSpeed)) : 1.0
        routeLoopEnabled = UserDefaults.standard.bool(forKey: "escape.routeLoopEnabled")
        locationGuard = UserDefaults.standard.bool(forKey: "escape.locationGuard")
        // 回前台立刻重发一次（守护 ON 且正在模拟时生效）。挂在单例上而不是某个页面，
        // 这样离开虚拟定位页、退后台再回来同样会被守护覆盖.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.guardResendOnForeground() }
        }
    }

    /// EscapeSpace 的配对文件（与「更多 → 应用」等共用 Documents/pairingFile.plist）.
    var hasPairing: Bool { TunnelContext.shared.hasPairingFile }
    var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard hasPairing else {
            lastError = "未检测到配对文件.请先在「设置 → 配对文件」导入（或使用 iPASide 安装时附带）."
            return
        }
        pin = coordinate
        apply(coordinate, markRecent: true)
    }

    var isMoving: Bool { routeActive || joystickActive }
    var canResumeRoute: Bool { routePaused && activeRoute.count >= 2 && simulated != nil }

    func adjustSpeed(by delta: Double) {
        speedMultiplier = min(4.0, max(0.25, speedMultiplier + delta))
    }

    /// 移动中按一次先暂停在当前模拟坐标；再按一次清除模拟定位返回真实 GPS.
    func stop() {
        if isMoving {
            stopMovement()
            return
        }
        stopResend()
        stopHealth()
        isBusy = true
        let result = LocationEngine.clear()
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            status = .idle
            lastError = nil
            endBackground()
            // 设置页保活开关未开时，任务结束即停止保活.
            KeepAliveManager.shared.stop()
            // v0.3.254：走 RSD 隧道 SIGKILL 设备侧 locationd（App 无越狱，本地 kill 无效）.
            locationdKilled = LocationEngine.killLocationd()
            // 继续轻量定位，让地图定位点回到真实 GPS.
            locationKeeper.start()
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// v0.3.254：清除流程结束后的状态收敛（**主线程调用**）.
    /// success = clear 成功且设备侧 locationd 已被 SIGKILL.
    func applyCleared(success: Bool) {
        isBusy = false
        if success {
            stopMovement()
            stopResend()
            stopHealth()
            simulated = nil
            status = .idle
            lastError = nil
            endBackground()
            KeepAliveManager.shared.stop()
            locationKeeper.start()
            locationdKilled = true
        } else {
            status = .dropped("清除虚拟定位失败")
        }
    }

    /// 最近一次真实设备坐标（非图钉）.
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// 真实 GPS 转换到 Apple 地图瓦片坐标显示.
    var realMapCoordinate: CLLocationCoordinate2D? {
        realCoordinate.map(ChinaCoordinateTransform.systemCoordinateToMapCoordinate)
    }

    /// 启动轻量 GPS 更新（地图定位点 / 回到真实位置）.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick() {
        guard hasPairing else {
            lastError = "未检测到配对文件.请先在「设置 → 配对文件」导入."
            return
        }
        routeTask?.cancel()
        routeTask = nil
        routeActive = false
        routePaused = false
        activeRoute.removeAll()
        let start = simulated ?? pin ?? realMapCoordinate
        guard let start else {
            lastError = "使用摇杆前请先放置图钉或开始模拟定位."
            return
        }
        if simulated == nil {
            apply(start, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick()
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopMovement() {
        let wasRouting = routeActive
        routeGeneration = UUID()
        routeTask?.cancel()
        routeTask = nil
        routeActive = false
        routePaused = wasRouting && activeRoute.count >= 2
        stopJoystick()
    }

    func resumeRoute() {
        guard canResumeRoute, let current = simulated else { return }
        let nearest = activeRoute.indices.min { lhs, rhs in
            Self.distance(from: current, to: activeRoute[lhs]) < Self.distance(from: current, to: activeRoute[rhs])
        } ?? activeRoute.startIndex
        var remaining = [current]
        remaining.append(contentsOf: activeRoute[nearest...])
        guard remaining.count >= 2 else { return }
        startRoute(remaining, preserveOriginalRoute: true)
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D]) {
        guard hasPairing, coordinates.count >= 2 else { return }
        activeRoute = coordinates
        routeProgress = 0
        routeLap = 0
        startRoute(coordinates, preserveOriginalRoute: true)
    }

    private func startRoute(_ coordinates: [CLLocationCoordinate2D], preserveOriginalRoute: Bool) {
        routeGeneration = UUID()
        let generation = routeGeneration
        routeTask?.cancel()
        stopJoystick()
        routeActive = true
        routePaused = false
        if !preserveOriginalRoute { activeRoute = coordinates }
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var firstPass = true
            var lap = 0
            repeat {
                if Task.isCancelled { break }
                lap += 1
                self.routeLap = lap
                var previous = coordinates[0]
                self.apply(previous, markRecent: firstPass)
                firstPass = false

                for (segmentIndex, next) in coordinates.dropFirst().enumerated() {
                    if Task.isCancelled { break }
                    let distance = Self.distance(from: previous, to: next)
                    var speed = mode.baseSpeed * self.speedMultiplier * Double.random(in: 0.88...1.12)
                    speed = max(0.2, speed)
                    let stepMeters: CLLocationDistance = min(12, max(1, speed * 0.5))
                    let steps = max(1, Int(ceil(distance / stepMeters)))
                    for i in 1...steps {
                        if Task.isCancelled { break }
                        let t = Double(i) / Double(steps)
                        let coord = CLLocationCoordinate2D(
                            latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                            longitude: previous.longitude + (next.longitude - previous.longitude) * t
                        )
                        speed = max(0.2, mode.baseSpeed * self.speedMultiplier * Double.random(in: 0.94...1.06))
                        let delay = max(0.05, stepMeters / speed)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if Task.isCancelled { break }
                        self.apply(coord, markRecent: false)
                        self.routeProgress = min(1, (Double(segmentIndex) + t) / Double(max(1, coordinates.count - 1)))
                    }
                    previous = next
                }
                if self.routeLoopEnabled { self.routeProgress = 0 }
            } while self.routeLoopEnabled && !Task.isCancelled
            guard self.routeGeneration == generation else { return }
            self.routeTask = nil
            self.routeActive = false
            self.routePaused = false
        }
    }

    private static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // 同名坐标处已有命名收藏时不覆盖.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// 收藏建议名（搜索结果 / 匹配最近使用）.
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "收藏" { return true }
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, markRecent: Bool) {
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            lastError = "所选地图坐标无效，请重新放置图钉."
            return
        }
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let systemCoordinate = ChinaCoordinateTransform.mapCoordinateToSystemCoordinate(coordinate)
        let result = LocationEngine.set(
            latitude: systemCoordinate.latitude,
            longitude: systemCoordinate.longitude,
            pairingPath: pairingPath,
            deviceIP: LocalDevVPN.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            beginBackground()
            locationKeeper.start()
            // 核心保活：即使离开本页 / 退到后台，模拟也持续生效.
            KeepAliveManager.shared.ensureRunning()
            startResend()
            startHealth()
            if markRecent {
                pushRecent(coordinate)
            }
        case .failure(let error):
            lastError = error.localizedDescription
            if simulated != nil {
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            } else {
                status = .idle
            }
        }
    }

    private func tickJoystick() {
        guard joystickActive, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * speedMultiplier * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, markRecent: false)
    }

    /// 周期性重发当前坐标（OFF 档 8s / 增强守护档 3s），防止会话被系统回收.
    /// 重发一律走 `LocationEngine.set`：内部有活动会话就复用同一条隧道，不会新建.
    private func startResend() {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: resendInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                self.resend(sim, source: .timer)
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    /// 健康检查（OFF 档 12s / 增强守护档 5s）：掉线自动重连.
    /// 守护 ON 时，检出会话被回收即**立刻**重建，不等下一个重发周期.
    /// v0.3.422：健康检查的**连续失败退避**状态。
    ///
    /// 为什么需要（真机事故 2026-09-18）：隧道建不起来时（设备端 `remotepairingd` 不响应），
    /// 原来的实现会**每 5 秒死循环重连** —— 实测连续 **63 次、持续 7 分钟**、每次都超时。
    /// 这既毫无意义（对方没恢复就永远失败），又会**持续占用设备端**，
    /// 让排在后面的其它依赖配对文件的功能（空间回收 / AFC / 设备控制…）一起被拖住。
    private var healthFailureStreak = 0
    private var lastHealthRetryAt: Date?

    private func startHealth() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }

                let needsReconnect: Bool
                if case .dropped = self.status {
                    needsReconnect = true
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    needsReconnect = true
                } else {
                    needsReconnect = false
                }

                guard needsReconnect else {
                    // 会话健康 → 清零退避（下次掉线从最短间隔重新开始）.
                    self.healthFailureStreak = 0
                    self.lastHealthRetryAt = nil
                    return
                }

                // ▸ 退避窗口：连续失败时把重试间隔指数放大（5s→10s→20s→40s→60s 封顶）。
                // 目的：对方不响应时**不再每 5 秒硬撞**，给设备端与其它功能让路。
                if let last = self.lastHealthRetryAt {
                    let backoff = min(60, self.healthInterval * pow(2, Double(min(self.healthFailureStreak, 4))))
                    if Date().timeIntervalSince(last) < backoff { return }
                }
                self.lastHealthRetryAt = Date()

                self.status = .reconnecting
                self.apply(sim, markRecent: false)
                self.noteGuardResend(.health, ok: self.status == .active, resetSuspected: true)
                self.healthFailureStreak = (self.status == .active) ? 0 : (self.healthFailureStreak + 1)
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// 回前台：守护 ON 且正在模拟时立刻重发一次.
    private func guardResendOnForeground() {
        guard locationGuard, isSpoofing, let sim = simulated else { return }
        resend(sim, source: .foreground)
    }

    /// 重发当前坐标并记录来源（复用同一条隧道）.
    /// OFF 档不计数、不写日志，与历史行为完全一致.
    private func resend(_ coordinate: CLLocationCoordinate2D, source: GuardTrigger) {
        let hadSession = LocationEngine.isSessionActive
        let systemCoordinate = ChinaCoordinateTransform.mapCoordinateToSystemCoordinate(coordinate)
        let result = LocationEngine.set(
            latitude: systemCoordinate.latitude,
            longitude: systemCoordinate.longitude,
            pairingPath: pairingPath,
            deviceIP: LocalDevVPN.targetIP
        )
        guard locationGuard else { return }
        var ok = false
        if case .success = result { ok = true }
        // 重发前链路已不在 → 记为一次「疑似复位」命中.
        noteGuardResend(source, ok: ok, resetSuspected: !hadSession)
    }

    /// 守护日志：来源 + 累计重发次数 + 疑似复位命中次数（前缀「[增强守护]」便于过滤）.
    private func noteGuardResend(_ source: GuardTrigger, ok: Bool, resetSuspected: Bool = false) {
        guard locationGuard else { return }
        guardResendTotal += 1
        if resetSuspected { guardResetHits += 1 }
        LoginLogger.shared.log(
            "[增强守护] 重发(\(source.rawValue)) \(ok ? "成功" : "失败") · 累计 \(guardResendTotal) 次 · 疑似复位 \(guardResetHits) 次"
        )
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "虚拟定位连接中断"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}

extension Notification.Name {
    /// 从其他 App 分享 .gpx 到 EscapeSpace 时投递（内容为 URL）.
    static let escapeImportGPX = Notification.Name("escapeImportGPX")
}
