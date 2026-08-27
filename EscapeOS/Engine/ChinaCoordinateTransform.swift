import CoreLocation
import Foundation

/// 把 Apple 中国地图瓦片（GCJ-02）上选择的坐标，转换回开发者定位服务
/// 期望的 WGS-84 坐标（移植自 locus-ZH，MIT）。
enum ChinaCoordinateTransform {
    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    /// Core Location 的 WGS-84 坐标 → Apple 中国地图瓦片坐标。
    static func systemCoordinateToMapCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        wgs84ToGCJ02(coordinate)
    }

    /// 地图瓦片坐标 → 系统坐标（中国大陆区域做 GCJ-02 反算，迭代收敛）。
    static func mapCoordinateToSystemCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard usesMainlandChinaOffset(coordinate) else { return coordinate }

        var estimate = coordinate
        for _ in 0..<8 {
            let projected = wgs84ToGCJ02(estimate)
            estimate.latitude -= projected.latitude - coordinate.latitude
            estimate.longitude -= projected.longitude - coordinate.longitude
        }
        return estimate
    }

    static func usesMainlandChinaOffset(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= 72.004 && coordinate.longitude <= 137.8347 &&
        coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271
    }

    private static func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard usesMainlandChinaOffset(coordinate) else { return coordinate }

        var latitudeDelta = transformLatitude(
            longitude: coordinate.longitude - 105.0,
            latitude: coordinate.latitude - 35.0
        )
        var longitudeDelta = transformLongitude(
            longitude: coordinate.longitude - 105.0,
            latitude: coordinate.latitude - 35.0
        )
        let radians = coordinate.latitude / 180.0 * .pi
        let sine = sin(radians)
        var magic = 1.0 - eccentricitySquared * sine * sine
        let squareRootMagic = sqrt(magic)
        latitudeDelta = latitudeDelta * 180.0 /
            ((semiMajorAxis * (1.0 - eccentricitySquared)) / (magic * squareRootMagic) * .pi)
        longitudeDelta = longitudeDelta * 180.0 /
            (semiMajorAxis / squareRootMagic * cos(radians) * .pi)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeDelta,
            longitude: coordinate.longitude + longitudeDelta
        )
    }

    private static func transformLatitude(longitude x: Double, latitude y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y +
            0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(longitude x: Double, latitude y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x +
            0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}
