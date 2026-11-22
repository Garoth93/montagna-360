import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CrestaCore

/// Synthetic data only (coordinates invented around 10°N 20°E).
enum Synthetic {
    static let t0 = Date(timeIntervalSince1970: 1_736_931_600) // 2025-01-15 09:00 UTC (winter)
    static let summer = Date(timeIntervalSince1970: 1_752_570_000) // 2025-07-15 09:00 UTC

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Straight line from `from`, `n` points every `dt` s, `dLat` per step, `dEle` per step.
    static func line(start: Date, from: Coordinate = Coordinate(lat: 10, lon: 20), ele: Double = 1500, n: Int,
                     dt: Double, dLat: Double, dEle: Double) -> [TrackPoint] {
        (0..<n).map { i in
            TrackPoint(lat: from.lat + Double(i) * dLat, lon: from.lon, ele: ele + Double(i) * dEle,
                       time: start.addingTimeInterval(Double(i) * dt))
        }
    }

    /// Ski touring: 1000 m up in 2.5 h (~1.8 km/h), down in 25 min (fast).
    static func skiTouring(start: Date = t0) -> Track {
        let up = line(start: start, n: 150, dt: 60, dLat: 0.0004, dEle: 1000.0 / 149)
        let last = up.last!
        let down = line(start: last.time!.addingTimeInterval(600), from: last.coordinate, ele: last.ele!, n: 50, dt: 30,
                        dLat: -0.0012, dEle: -1000.0 / 49)
        return Track(points: up + down)
    }

    /// Resort: 4 × (lift 400 m in 6 min, run 400 m in 4 min at ~40 km/h).
    static func resort(start: Date = t0) -> Track {
        var pts: [TrackPoint] = []
        var t = start
        var c = Coordinate(lat: 10, lon: 20)
        for _ in 0..<4 {
            for i in 0..<13 {
                pts.append(TrackPoint(lat: c.lat + Double(i) * 0.0002, lon: c.lon, ele: 1500 + Double(i) * 33.3, time: t))
                t += 30
            }
            c.lat += 12 * 0.0002
            for i in 1...24 {
                pts.append(TrackPoint(lat: c.lat - Double(i) * 0.001, lon: c.lon + Double(i) * 0.00002, ele: 1900 - Double(i) * 16.7, time: t))
                t += 10
            }
            c.lat -= 24 * 0.001
            c.lon += 24 * 0.00002
        }
        return Track(points: pts)
    }

    /// Summer bike ride, 25 km/h, rolling.
    static func bike(start: Date = summer) -> Track {
        Track(points: (0..<200).map { i in
            TrackPoint(lat: 10 + Double(i) * 0.0007, lon: 20, ele: 500 + 80 * sin(Double(i) / 15), time: start.addingTimeInterval(Double(i) * 11))
        })
    }

    /// Summer hike to the synthetic peak at (10.06, 20.0).
    static func hike(start: Date = summer) -> Track {
        let up = line(start: start, n: 151, dt: 60, dLat: 0.0004, dEle: 6)
        let last = up.last!
        let down = line(start: last.time!.addingTimeInterval(1200), from: last.coordinate, ele: last.ele!, n: 101, dt: 60,
                        dLat: -0.0006, dEle: -9)
        return Track(points: up + down)
    }

    static let peak = Peak(id: "osm:1", name: "Cima Test", lat: 10.06, lon: 20.0, elevation: 2400)
    static let farPeak = Peak(id: "osm:2", name: "Punta Lontana", lat: 10.2, lon: 20.2, elevation: 3000)

    static func gpx(_ pts: [TrackPoint], type: String? = nil) -> String {
        let f = ISO8601DateFormatter()
        let body = pts.map { p in
            "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">" + (p.ele.map { "<ele>\($0)</ele>" } ?? "") + (p.time.map { "<time>\(f.string(from: $0))</time>" } ?? "") + "</trkpt>"
        }.joined()
        return "<?xml version=\"1.0\"?><gpx xmlns=\"http://www.topografix.com/GPX/1/1\"><metadata><name>Meta</name></metadata><trk><name>Uscita sintetica</name>" + (type.map { "<type>\($0)</type>" } ?? "") + "<trkseg>\(body)</trkseg></trk></gpx>"
    }

    static let deflateText = String(repeating: "Cresta test ", count: 50) + String((0..<3000).map { Character(UnicodeScalar(UInt8(65 + ($0 * 7) % 26))) })
    static let deflateB64 = "cy5KLS5JVCgBkgrOo+xRNpXYjh7+Yc5egRGuPsFR7n6hTp4B4S7eQZFuviGjMqMyozKjMqMyozKjMqMyozKjMqMyg0UGAA=="
    static let fixedB64 = "S0xKToQhhYzUnJx8ZBIA"
    static let gpxGzB64 = "H4sIAAAAAAAC/42Y3WoaYRRFX0W8T/zO+f7DZHLZF+hV76QMVmKMmKGkb1/H1OawCZsjgs4o2+XFmgUzPL2/HFa/p/Pb/vX4uJb7sH4ah93p3Z6T9ernedrOr+fH9Ty9zetxmM/P43Dcvkzjt/28XS1nh831eJj/nKbx1/55f9wNm+vB8u23aXd9Pc2rw3a+rIb7cH2sV4flV/T/8ThMh2mUHMKwWd4N8/4yq0HzXZA7yd9Dfwjh8vxxmV8+urwsu1/MZ5iPZl4ymRfPvCB9MfOR0atrHum7mU+MPnrmFehFzXxh9Mk1D/TXf3Obr4w+e+Yj0jcz3xl9cc0DvcrnfAmMvnrmE9BrMvPK6JtrHumrmY+MvnvmM9BHY23JhF5c1magj8baUgi9uKwtSG+sLY3Ru6wtSG+sLZ3Ru6ytQJ+MtVUYvcvaCvTJWFuV0busbUhvrK2J0busbUCfjbU1M3qXtR3os7G2VkbvsrYjvbG2NkbvsVawtcVY21hrNbjmgb4YaxtrrXqsFWxtMdY21lpV1zzSG2sba616rBVsbTXWNtZaTa55oK/G2sZaqx5rBVtbjbWNtVaLax7om7G2s9aqx1rB1jZjbWet1eaaR3pjbWetVZe12NpurO2stdFlLba2G2s7a210WYut7cbazlobXdZia7uxtrPWRpe10FoJn9ZqYK2NLmuhtR9X0Ns8a210WduQvpl51troshZaKyJmnrU2uqyF1ookM89aG13WdqSvZp61NnqsVWjtx/X/37yw1qbgmgd6jWaetTZ5rFVB+mLmWWuTuuaRvpt51trksVahtRKNtcJam5JrHuijsVZYa5PHWo1Ib6wV1tpUXPNAn4y1ylqbPNYqtFaSsVZZa1NzzSO9sVZZa5PLWmjtR3tv86y12WUttHa5RfQ5z1qbXdYWpDfWKmttdllbkN5Yq6y12WUttrYYayNrbXZZi60txtrIWptd1mJri7E2stZml7XY2mqsjay12WUttrYaayNrbXZZi62txtrIWpu/tHZzu5m8ud6D3uxO7+NfNvIngsYWAAA="
}

/// Fake HTTP transport for the Strava engine.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) -> HTTPResponse
    var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) -> HTTPResponse) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return handler(request)
    }
}

final class RecordingDelegate: StravaSyncDelegate, @unchecked Sendable {
    var imported: [(StravaSummary, Track?)] = []
    var states: [StravaSyncState] = []
    var tokens: [StravaTokens] = []

    func tokensChanged(_ tokens: StravaTokens) async { self.tokens.append(tokens) }
    func stateChanged(_ state: StravaSyncState) async { states.append(state) }
    func importActivity(_ summary: StravaSummary, track: Track?) async -> Bool { imported.append((summary, track)); return true }
}
