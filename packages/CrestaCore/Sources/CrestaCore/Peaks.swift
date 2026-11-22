import Foundation

/// A summit from OpenStreetMap (`natural=peak` with a name).
public struct Peak: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// OSM node id (`osm:123`) or `user:<uuid>` for peaks added by hand.
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var elevation: Double?

    public init(id: String, name: String, lat: Double, lon: Double, elevation: Double?) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.elevation = elevation
    }

    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

/// The bundled offline file: one peak per line, tab separated:
/// `osmId \t lat \t lon \t ele \t name` (ele may be empty).
public enum PeakFile {
    public static func parse(_ text: String) -> [Peak] {
        var out: [Peak] = []
        out.reserveCapacity(text.utf8.count / 40)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let lat = Double(f[1]), let lon = Double(f[2]) else { continue }
            let name = f[4].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            out.append(Peak(id: "osm:\(f[0])", name: name, lat: lat, lon: lon, elevation: parseElevation(String(f[3]))))
        }
        return out
    }

    /// OSM `ele` values: "3343", "3343 m", "3.343", "3343;3340", "10000 ft".
    public static func parseElevation(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        let feet = s.hasSuffix("ft") || s.hasSuffix("'")
        s = s.replacingOccurrences(of: "m", with: "").replacingOccurrences(of: "ft", with: "")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
        if s.contains(","), !s.contains(".") { s = s.replacingOccurrences(of: ",", with: ".") }
        // "3.343" with three decimals is a thousands separator.
        if let dot = s.firstIndex(of: "."), s.distance(from: dot, to: s.endIndex) == 4, Double(s) ?? 0 < 10 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard let v = Double(s), v > -500, v < 9000 * (feet ? 3.3 : 1) else { return nil }
        return feet ? v * 0.3048 : v
    }

    public static func serialize(_ peaks: [Peak]) -> String {
        peaks.map { p in
            let id = p.id.hasPrefix("osm:") ? String(p.id.dropFirst(4)) : p.id
            let ele = p.elevation.map { String(Int($0.rounded())) } ?? ""
            let name = p.name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            return "\(id)\t\(String(format: "%.6f", p.lat))\t\(String(format: "%.6f", p.lon))\t\(ele)\t\(name)"
        }.joined(separator: "\n")
    }

    /// Overpass API query for named peaks in a box (in-app area download).
    public static func overpassQuery(_ box: BoundingBox) -> String {
        "[out:csv(::id,::lat,::lon,ele,name;false;\"\\t\")][timeout:90];node[\"natural\"=\"peak\"][\"name\"](\(box.minLat),\(box.minLon),\(box.maxLat),\(box.maxLon));out;"
    }
}

/// Spatial index (0.05° grid cells) for fast "peaks near here" queries.
public struct PeakIndex: Sendable {
    public let peaks: [Peak]
    private let cells: [Int64: [Int32]]
    private static let cell = 0.05

    public init(peaks: [Peak]) {
        // Deduplicate by id (bundled + downloaded + user peaks).
        var seen = Set<String>()
        let unique = peaks.filter { seen.insert($0.id).inserted }
        self.peaks = unique
        var c: [Int64: [Int32]] = [:]
        for (i, p) in unique.enumerated() { c[Self.key(p.lat, p.lon), default: []].append(Int32(i)) }
        cells = c
    }

    static func key(_ lat: Double, _ lon: Double) -> Int64 {
        let y = Int64(floor((lat + 90) / cell)), x = Int64(floor((lon + 180) / cell))
        return y * 100_000 + x
    }

    public var count: Int { peaks.count }

    public func peak(id: String) -> Peak? { peaks.first { $0.id == id } }

    public func peaks(in box: BoundingBox, limit: Int = .max) -> [Peak] {
        var out: [Peak] = []
        var lat = floor(box.minLat / Self.cell) * Self.cell
        while lat <= box.maxLat {
            var lon = floor(box.minLon / Self.cell) * Self.cell
            while lon <= box.maxLon {
                for i in cells[Self.key(lat + 1e-9, lon + 1e-9)] ?? [] {
                    let p = peaks[Int(i)]
                    if box.contains(p.coordinate) { out.append(p) }
                }
                lon += Self.cell
            }
            lat += Self.cell
        }
        if out.count > limit {
            // Keep the highest ones when the map is zoomed out.
            out.sort { ($0.elevation ?? 0) > ($1.elevation ?? 0) }
            out = Array(out.prefix(limit))
        }
        return out
    }

    public func nearest(to c: Coordinate, within meters: Double) -> [(peak: Peak, distance: Double)] {
        let d = Geo.degrees(meters: meters, atLat: c.lat)
        let box = BoundingBox(minLat: c.lat - d.dLat, minLon: c.lon - d.dLon, maxLat: c.lat + d.dLat, maxLon: c.lon + d.dLon)
        return peaks(in: box)
            .map { ($0, Geo.distance(c, $0.coordinate)) }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
    }

    public func search(_ query: String, limit: Int = 50) -> [Peak] {
        let q = Search.fold(query)
        guard !q.isEmpty else { return [] }
        var prefix: [Peak] = [], contains: [Peak] = []
        for p in peaks {
            let n = Search.fold(p.name)
            if n.hasPrefix(q) { prefix.append(p) } else if n.contains(q) { contains.append(p) }
            if prefix.count >= limit { break }
        }
        let byEle: (Peak, Peak) -> Bool = { ($0.elevation ?? 0) > ($1.elevation ?? 0) }
        return Array((prefix.sorted(by: byEle) + contains.sorted(by: byEle)).prefix(limit))
    }
}

public enum Search {
    /// Lowercased, accents removed.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Finds the peaks a track went over.
public enum SummitMatcher {
    public struct Match: Equatable, Sendable {
        public var peakID: String
        public var time: Date?
        public var distance: Double
        public var trackElevation: Double?
    }

    /// A peak is reached when the track passes within `radius` meters of it
    /// and — if both have an altitude — no more than `maxBelow` meters lower
    /// (GPS altitude is noisy: the tolerance is generous).
    public static func match(track: Track, index: PeakIndex, radius: Double = 60, maxBelow: Double = 80) -> [Match] {
        guard let box = track.boundingBox?.expanded(meters: radius) else { return [] }
        let candidates = index.peaks(in: box)
        guard !candidates.isEmpty else { return [] }
        var best: [String: Match] = [:]
        // Thin very dense tracks for speed; keep ≤ ~5 m spacing semantics by radius.
        let pts = track.points
        for p in candidates {
            let pc = p.coordinate
            let d = Geo.degrees(meters: radius, atLat: p.lat)
            for tp in pts {
                guard abs(tp.lat - p.lat) <= d.dLat, abs(tp.lon - p.lon) <= d.dLon else { continue }
                let dist = Geo.fastDistance(tp.coordinate, pc)
                guard dist <= radius else { continue }
                if let pe = p.elevation, let te = tp.ele, te < pe - maxBelow { continue }
                if dist < (best[p.id]?.distance ?? .infinity) {
                    best[p.id] = Match(peakID: p.id, time: tp.time, distance: dist, trackElevation: tp.ele)
                }
            }
        }
        return best.values.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
    }
}
