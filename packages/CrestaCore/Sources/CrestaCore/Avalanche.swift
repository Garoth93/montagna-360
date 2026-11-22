import Foundation

/// European avalanche danger scale 1…5.
public enum DangerLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 1, moderate, considerable, high, veryHigh

    public static func < (a: DangerLevel, b: DangerLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .low: return "1 · Debole"
        case .moderate: return "2 · Moderato"
        case .considerable: return "3 · Marcato"
        case .high: return "4 · Forte"
        case .veryHigh: return "5 · Molto forte"
        }
    }

    public var colorHex: String {
        switch self {
        case .low: return "#7cb342"
        case .moderate: return "#fdd835"
        case .considerable: return "#fb8c00"
        case .high: return "#e53935"
        case .veryHigh: return "#212121"
        }
    }

    /// CAAML v6 `mainValue`.
    public init?(caaml: String) {
        switch caaml {
        case "low": self = .low
        case "moderate": self = .moderate
        case "considerable": self = .considerable
        case "high": self = .high
        case "very_high": self = .veryHigh
        default: return nil
        }
    }

    /// Italian words used by Italian bulletins.
    public init?(italian: String) {
        let s = Search.fold(italian)
        if s.contains("molto forte") { self = .veryHigh } else if s.contains("forte") { self = .high } else if s.contains("marcato") { self = .considerable } else if s.contains("moderato") { self = .moderate } else if s.contains("debole") { self = .low } else { return nil }
    }
}

public struct AvalancheReport: Codable, Equatable, Sendable {
    public var regionID: String
    public var regionName: String?
    /// Highest danger level for the day (all elevations).
    public var maxLevel: DangerLevel?
    /// Level above / below the elevation threshold, when split.
    public var levelAbove: DangerLevel?
    public var levelBelow: DangerLevel?
    public var threshold: Int?
    public var problems: [String]
    public var highlights: String?
    public var validUntil: Date?
    public var fetchedAt: Date
    public var source: String

    public init(regionID: String, regionName: String? = nil, maxLevel: DangerLevel?, levelAbove: DangerLevel? = nil,
                levelBelow: DangerLevel? = nil, threshold: Int? = nil, problems: [String] = [], highlights: String? = nil,
                validUntil: Date? = nil, fetchedAt: Date, source: String) {
        self.regionID = regionID; self.regionName = regionName; self.maxLevel = maxLevel
        self.levelAbove = levelAbove; self.levelBelow = levelBelow; self.threshold = threshold
        self.problems = problems; self.highlights = highlights; self.validUntil = validUntil
        self.fetchedAt = fetchedAt; self.source = source
    }

    /// Level that applies at a given altitude.
    public func level(at elevation: Double?) -> DangerLevel? {
        guard let elevation, let threshold, let a = levelAbove, let b = levelBelow else { return maxLevel }
        return elevation >= Double(threshold) ? a : b
    }
}

/// Bulletins: EAWS CAAML v6 JSON (all regions, including the Veneto
/// bulletin of ARPAV, code IT-34) with a fallback that reads a web page.
public enum AvalancheBulletin {
    /// `regionPrefix` e.g. "IT-34" (Veneto), "IT-32-TN", "IT-32-BZ", "IT-23" (VdA).
    public static func caamlURL(regionPrefix: String, day: String) -> URL {
        let top = regionPrefix.split(separator: "-").prefix(2).joined(separator: "-")
        let file = regionPrefix.hasPrefix("IT-32") ? regionPrefix : top
        return URL(string: "https://static.avalanche.report/eaws_bulletins/\(day)/\(day)-\(file).json")!
    }

    public static let problemNames: [String: String] = [
        "new_snow": "Neve fresca", "wind_slab": "Neve ventata", "persistent_weak_layers": "Strati deboli persistenti",
        "wet_snow": "Neve bagnata", "gliding_snow": "Valanghe di slittamento", "cornices": "Cornici",
        "no_distinct_avalanche_problem": "Nessun problema evidente", "favourable_situation": "Situazione favorevole"
    ]

    /// Parses CAAML v6 JSON and keeps the bulletin covering `regionID`
    /// (exact micro-region like "IT-34-BL-01", or a prefix: the worst one wins).
    public static func parseCAAML(_ data: Data, regionID: String, fetchedAt: Date = Date()) throws -> AvalancheReport? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bulletins = root["bulletins"] as? [[String: Any]] else { return nil }
        var best: AvalancheReport?
        for b in bulletins {
            let regions = (b["regions"] as? [[String: Any]]) ?? []
            guard let region = regions.first(where: { ($0["regionID"] as? String).map { $0 == regionID || $0.hasPrefix(regionID) } ?? false })
                    ?? (regionID.isEmpty ? regions.first : nil) else { continue }
            var maxLevel: DangerLevel?
            var above: DangerLevel?, below: DangerLevel?, threshold: Int?
            for r in (b["dangerRatings"] as? [[String: Any]]) ?? [] {
                guard let lv = (r["mainValue"] as? String).flatMap(DangerLevel.init(caaml:)) else { continue }
                maxLevel = max(maxLevel ?? lv, lv)
                if let el = r["elevation"] as? [String: Any] {
                    if let lb = el["lowerBound"] { above = max(above ?? lv, lv); threshold = Int("\(lb)") ?? threshold }
                    if let ub = el["upperBound"] { below = max(below ?? lv, lv); threshold = Int("\(ub)") ?? threshold }
                }
            }
            let problems = ((b["avalancheProblems"] as? [[String: Any]]) ?? []).compactMap { $0["problemType"] as? String }
                .map { problemNames[$0] ?? $0 }
            let highlights = ((b["avalancheActivity"] as? [String: Any])?["highlights"] as? String)
            let valid = ((b["validTime"] as? [String: Any])?["endTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let report = AvalancheReport(regionID: region["regionID"] as? String ?? regionID, regionName: region["name"] as? String,
                                         maxLevel: maxLevel, levelAbove: above, levelBelow: below, threshold: threshold,
                                         problems: problems.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                                         highlights: highlights.map(stripHTML), validUntil: valid, fetchedAt: fetchedAt, source: "EAWS CAAML")
            if best == nil || (report.maxLevel ?? .low) > (best?.maxLevel ?? .low) { best = report }
        }
        return best
    }

    /// Fallback: reads the bulletin web page and looks for the danger level,
    /// either as "grado 3" / "pericolo 3" or as the Italian word.
    public static func parseHTML(_ html: String, regionID: String, fetchedAt: Date = Date()) -> AvalancheReport? {
        let text = Search.fold(stripHTML(html))
        var levels: [DangerLevel] = []
        let patterns = ["grado di pericolo", "pericolo valanghe", "grado", "pericolo"]
        for p in patterns {
            var search = text.startIndex
            while let r = text.range(of: p, range: search..<text.endIndex) {
                let window = text[r.upperBound..<(text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex)]
                if let digit = window.first(where: { ("1"..."5").contains($0) }), let n = Int(String(digit)),
                   let lv = DangerLevel(rawValue: n), window.prefix(while: { $0 != digit }).count < 12 {
                    levels.append(lv)
                } else if let lv = DangerLevel(italian: String(window)) {
                    levels.append(lv)
                }
                search = r.upperBound
            }
            if !levels.isEmpty { break }
        }
        guard let worst = levels.max() else { return nil }
        return AvalancheReport(regionID: regionID, maxLevel: worst, fetchedAt: fetchedAt, source: "Pagina web")
    }

    public static func stripHTML(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; out.append(" ") } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) }
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
