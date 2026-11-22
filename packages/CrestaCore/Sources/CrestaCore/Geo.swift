import Foundation

/// WGS84 coordinate (degrees).
public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    public var isValid: Bool {
        lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180 && !(lat == 0 && lon == 0)
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance in meters.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Fast equirectangular approximation, good below a few km.
    public static func fastDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let x = (b.lon - a.lon) * .pi / 180 * cos((a.lat + b.lat) / 2 * .pi / 180)
        let y = (b.lat - a.lat) * .pi / 180
        return (x * x + y * y).squareRoot() * earthRadius
    }

    /// Degrees of latitude / longitude spanning `meters` around `lat`.
    public static func degrees(meters: Double, atLat lat: Double) -> (dLat: Double, dLon: Double) {
        let dLat = meters / 111_320
        let dLon = meters / (111_320 * max(0.01, cos(lat * .pi / 180)))
        return (dLat, dLon)
    }
}

public struct BoundingBox: Codable, Equatable, Sendable {
    public var minLat: Double
    public var minLon: Double
    public var maxLat: Double
    public var maxLon: Double

    public init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.minLat = minLat
        self.minLon = minLon
        self.maxLat = maxLat
        self.maxLon = maxLon
    }

    public init?(coordinates: [Coordinate]) {
        guard let first = coordinates.first else { return nil }
        var b = BoundingBox(minLat: first.lat, minLon: first.lon, maxLat: first.lat, maxLon: first.lon)
        for c in coordinates.dropFirst() {
            b.minLat = min(b.minLat, c.lat); b.maxLat = max(b.maxLat, c.lat)
            b.minLon = min(b.minLon, c.lon); b.maxLon = max(b.maxLon, c.lon)
        }
        self = b
    }

    public var center: Coordinate { Coordinate(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2) }

    public func expanded(meters: Double) -> BoundingBox {
        let d = Geo.degrees(meters: meters, atLat: center.lat)
        return BoundingBox(minLat: minLat - d.dLat, minLon: minLon - d.dLon, maxLat: maxLat + d.dLat, maxLon: maxLon + d.dLon)
    }

    public func contains(_ c: Coordinate) -> Bool {
        c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
    }
}
