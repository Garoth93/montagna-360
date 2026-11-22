import Foundation

/// One GPS sample. Altitude, time and speed are optional (GPX without time,
/// FIT without position…).
public struct TrackPoint: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var time: Date?
    /// Speed reported by the device (m/s), if any.
    public var speed: Double?
    public var heartRate: Int?

    public init(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil, speed: Double? = nil, heartRate: Int? = nil) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
        self.speed = speed
        self.heartRate = heartRate
    }

    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }

    enum CodingKeys: String, CodingKey { case lat = "a", lon = "o", ele = "e", time = "t", speed = "s", heartRate = "h" }
}

/// A recorded track (from a file, Strava, or — in a later phase — the
/// phone's own GPS through `TrackRecorder`).
public struct Track: Codable, Equatable, Sendable {
    public var points: [TrackPoint]

    public init(points: [TrackPoint]) {
        self.points = points.filter { $0.coordinate.isValid }
    }

    public var isEmpty: Bool { points.isEmpty }
    public var start: Date? { points.first(where: { $0.time != nil })?.time }
    public var end: Date? { points.last(where: { $0.time != nil })?.time }
    public var coordinates: [Coordinate] { points.map(\.coordinate) }
    public var boundingBox: BoundingBox? { BoundingBox(coordinates: coordinates) }

    /// Keeps the shape with far fewer points (Douglas–Peucker on the plane,
    /// tolerance in meters). Used to store compact tracks and draw maps.
    public func simplified(tolerance: Double = 5) -> Track {
        guard points.count > 2 else { return self }
        let lat0 = points[0].lat * .pi / 180
        let xs = points.map { $0.lon * .pi / 180 * cos(lat0) * Geo.earthRadius }
        let ys = points.map { $0.lat * .pi / 180 * Geo.earthRadius }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            let dx = xs[e] - xs[s], dy = ys[e] - ys[s]
            let len = (dx * dx + dy * dy).squareRoot()
            var maxD = -1.0, idx = s
            for i in (s + 1)..<e {
                let d: Double
                if len < 1e-9 {
                    d = ((xs[i] - xs[s]) * (xs[i] - xs[s]) + (ys[i] - ys[s]) * (ys[i] - ys[s])).squareRoot()
                } else {
                    d = abs(dy * xs[i] - dx * ys[i] + xs[e] * ys[s] - ys[e] * xs[s]) / len
                }
                // Keep altitude turning points too: they matter for ascent.
                var altD = 0.0
                if let ea = points[s].ele, let eb = points[e].ele, let ei = points[i].ele {
                    let t = Double(i - s) / Double(e - s)
                    altD = abs(ei - (ea + (eb - ea) * t))
                }
                let score = max(d, altD * 2)
                if score > maxD { maxD = score; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx)); stack.append((idx, e))
            }
        }
        return Track(points: zip(points, keep).compactMap { $1 ? $0 : nil })
    }

    /// Evenly thinned copy with at most `maxPoints` points.
    public func thinned(maxPoints: Int) -> Track {
        guard points.count > maxPoints, maxPoints > 1 else { return self }
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        return Track(points: (0..<maxPoints).map { points[Int((Double($0) * step).rounded())] })
    }
}

/// Summary numbers of a track.
public struct TrackStats: Codable, Equatable, Sendable {
    public var distance: Double            // m
    public var ascent: Double              // m
    public var descent: Double             // m
    public var elapsed: TimeInterval       // s
    public var moving: TimeInterval        // s
    public var maxSpeed: Double            // m/s
    public var maxElevation: Double?
    public var minElevation: Double?
    /// Average speed while moving uphill / downhill (m/s) and vertical
    /// speeds (m/h): the inputs of the activity classifier.
    public var ascentSpeed: Double
    public var descentSpeed: Double
    public var verticalUpRate: Double
    public var verticalDownRate: Double
    /// Lift-like climbs (fast, steady vertical gain) and downhill runs.
    public var liftRides: Int
    public var runs: Int
    public var averageHeartRate: Int?

    public init(distance: Double = 0, ascent: Double = 0, descent: Double = 0, elapsed: TimeInterval = 0,
                moving: TimeInterval = 0, maxSpeed: Double = 0, maxElevation: Double? = nil, minElevation: Double? = nil,
                ascentSpeed: Double = 0, descentSpeed: Double = 0, verticalUpRate: Double = 0, verticalDownRate: Double = 0,
                liftRides: Int = 0, runs: Int = 0, averageHeartRate: Int? = nil) {
        self.distance = distance; self.ascent = ascent; self.descent = descent; self.elapsed = elapsed
        self.moving = moving; self.maxSpeed = maxSpeed; self.maxElevation = maxElevation; self.minElevation = minElevation
        self.ascentSpeed = ascentSpeed; self.descentSpeed = descentSpeed
        self.verticalUpRate = verticalUpRate; self.verticalDownRate = verticalDownRate
        self.liftRides = liftRides; self.runs = runs; self.averageHeartRate = averageHeartRate
    }

    public var averageMovingSpeed: Double { moving > 0 ? distance / moving : 0 }

    public static func compute(_ track: Track) -> TrackStats {
        let pts = track.points
        guard pts.count > 1 else {
            return TrackStats(maxElevation: pts.first?.ele, minElevation: pts.first?.ele)
        }
        var s = TrackStats()
        // Elevation: light smoothing, then hysteresis (3 m) to ignore noise.
        let eles = smoothedElevations(pts)
        if let e = eles {
            var ref = e[0]
            s.maxElevation = e.max(); s.minElevation = e.min()
            for v in e.dropFirst() {
                let d = v - ref
                if d >= 3 { s.ascent += d; ref = v } else if d <= -3 { s.descent -= d; ref = v }
            }
        }
        var upDist = 0.0, upTime = 0.0, downDist = 0.0, downTime = 0.0, upGain = 0.0, downLoss = 0.0
        var hrSum = 0, hrCount = 0
        var speeds: [Double] = []
        for i in 1..<pts.count {
            let d = Geo.fastDistance(pts[i - 1].coordinate, pts[i].coordinate)
            s.distance += d
            if let hr = pts[i].heartRate, hr > 0 { hrSum += hr; hrCount += 1 }
            guard let t0 = pts[i - 1].time, let t1 = pts[i].time else { continue }
            let dt = t1.timeIntervalSince(t0)
            guard dt > 0 else { continue }
            let v = pts[i].speed ?? d / dt
            speeds.append(dt <= 30 ? v : 0)
            // Moving: faster than 0.5 m/s, gaps longer than 5 min are pauses.
            if v > 0.5 && dt < 300 {
                s.moving += dt
                if let e = eles {
                    let de = e[i] - e[i - 1]
                    if de > 0.2 { upDist += d; upTime += dt; upGain += de } else if de < -0.2 { downDist += d; downTime += dt; downLoss -= de }
                }
            }
        }
        if let a = track.start, let b = track.end { s.elapsed = max(0, b.timeIntervalSince(a)) }
        // Max speed: median of 5 to drop GPS spikes; cap at 200 km/h.
        if speeds.count >= 5 {
            var best = 0.0
            for i in 2..<(speeds.count - 2) {
                let w = speeds[(i - 2)...(i + 2)].sorted()[2]
                best = max(best, w)
            }
            s.maxSpeed = min(best, 55.5)
        } else {
            s.maxSpeed = min(speeds.max() ?? 0, 55.5)
        }
        s.ascentSpeed = upTime > 0 ? upDist / upTime : 0
        s.descentSpeed = downTime > 0 ? downDist / downTime : 0
        s.verticalUpRate = upTime > 0 ? upGain / upTime * 3600 : 0
        s.verticalDownRate = downTime > 0 ? downLoss / downTime * 3600 : 0
        if let e = eles {
            let segs = ClimbSegmenter.segments(points: pts, elevations: e)
            s.liftRides = segs.filter { $0.kind == .lift }.count
            s.runs = segs.filter { $0.kind == .run }.count
        }
        if hrCount > 0 { s.averageHeartRate = hrSum / hrCount }
        return s
    }

    static func smoothedElevations(_ pts: [TrackPoint]) -> [Double]? {
        let withEle = pts.filter { $0.ele != nil }.count
        guard withEle * 2 >= pts.count, withEle > 1 else { return nil }
        // Fill gaps with the previous value.
        var raw: [Double] = []
        var last = pts.first(where: { $0.ele != nil })?.ele ?? 0
        for p in pts { if let e = p.ele { last = e }; raw.append(last) }
        // Smooth only dense tracks: on simplified tracks every point matters.
        var dist = 0.0
        for i in 1..<pts.count { dist += Geo.fastDistance(pts[i - 1].coordinate, pts[i].coordinate) }
        guard dist / Double(pts.count - 1) < 40 else { return raw }
        let k = 2
        return raw.indices.map { i in
            let lo = max(0, i - k), hi = min(raw.count - 1, i + k)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}

/// Splits a track into monotone altitude segments to count lift rides and
/// downhill runs (resort skiing, Slopes-style).
public enum ClimbSegmenter {
    public enum Kind: String, Codable, Sendable { case lift, climb, run, flat }

    public struct Segment: Equatable, Sendable {
        public var kind: Kind
        public var startIndex: Int
        public var endIndex: Int
        public var verticalChange: Double
        public var duration: TimeInterval
        public var distance: Double
    }

    /// A segment is a run if it loses ≥ 50 m; a climb is a lift if it gains
    /// ≥ 80 m faster than 1000 m/h (nobody skins up that fast for long).
    public static func segments(points: [TrackPoint], elevations: [Double]) -> [Segment] {
        guard points.count > 2, elevations.count == points.count else { return [] }
        var out: [Segment] = []
        var start = 0
        var extreme = 0
        var dir = 0 // 1 up, -1 down
        let threshold = 20.0
        func close(_ s: Int, _ e: Int) {
            guard e > s else { return }
            let dv = elevations[e] - elevations[s]
            var dist = 0.0
            for i in (s + 1)...e { dist += Geo.fastDistance(points[i - 1].coordinate, points[i].coordinate) }
            let dur: TimeInterval = {
                if let a = points[s].time, let b = points[e].time { return b.timeIntervalSince(a) }
                return 0
            }()
            let kind: Kind
            if dv <= -50 {
                kind = .run
            } else if dv >= 80, dur > 0, dv / dur * 3600 > 1000 {
                kind = .lift
            } else if dv >= 50 {
                kind = .climb
            } else {
                kind = .flat
            }
            out.append(Segment(kind: kind, startIndex: s, endIndex: e, verticalChange: dv, duration: dur, distance: dist))
        }
        for i in 1..<elevations.count {
            let v = elevations[i]
            switch dir {
            case 0:
                if v - elevations[start] >= threshold { dir = 1; extreme = i } else if elevations[start] - v >= threshold { dir = -1; extreme = i }
            case 1:
                if v >= elevations[extreme] { extreme = i } else if elevations[extreme] - v >= threshold {
                    close(start, extreme); start = extreme; extreme = i; dir = -1
                }
            default:
                if v <= elevations[extreme] { extreme = i } else if v - elevations[extreme] >= threshold {
                    close(start, extreme); start = extreme; extreme = i; dir = 1
                }
            }
        }
        if dir != 0 { close(start, extreme) }
        return out
    }
}
