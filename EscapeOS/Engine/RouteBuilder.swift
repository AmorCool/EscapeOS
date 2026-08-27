import CoreLocation
import Foundation
import MapKit

/// 路线构建与 GPX 编解码（移植自 locus-ZH）。
enum RouteBuilder {
    static func roadRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> [CLLocationCoordinate2D] {
        let candidates: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            (start, end),
            (
                ChinaCoordinateTransform.mapCoordinateToSystemCoordinate(start),
                ChinaCoordinateTransform.mapCoordinateToSystemCoordinate(end)
            )
        ]

        for (candidateStart, candidateEnd) in candidates {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: candidateStart))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: candidateEnd))
            request.transportType = mode.mkTransportType
            request.requestsAlternateRoutes = false

            if let response = try? await MKDirections(request: request).calculate(),
               let route = response.routes.first {
                let coordinates = sample(polyline: route.polyline, every: 12)
                // 轨迹播放坐标统一用地图坐标系。
                if ChinaCoordinateTransform.usesMainlandChinaOffset(start),
                   candidateStart.latitude != start.latitude {
                    return coordinates.map(ChinaCoordinateTransform.systemCoordinateToMapCoordinate)
                }
                return coordinates
            }
        }

        // Apple 路线服务在部分网络不可用；退化为起点到终点的直线备用路线。
        return sample(coordinates: [start, end], every: 10)
    }

    static func sample(polyline: MKPolyline, every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return sample(coordinates: coords, every: meters)
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / meters)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        return sampled
    }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // 兼容 lon 在前 lat 在后的写法
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "EscapeSpace", code: 2, userInfo: [NSLocalizedDescriptionKey: "GPX 中没有找到轨迹点"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "EscapeSpace Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="EscapeSpace" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
