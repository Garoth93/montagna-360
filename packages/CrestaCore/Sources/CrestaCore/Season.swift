import Foundation

/// Winter / non-winter switch. Automatic by date, overridable by hand.
public enum SeasonMode: String, Codable, CaseIterable, Sendable {
    case automatic, winter, summer

    public var title: String {
        switch self {
        case .automatic: return "Automatica"
        case .winter: return "Inverno"
        case .summer: return "Non inverno"
        }
    }
}

public struct Season: Hashable, Codable, Sendable, Comparable, Identifiable {
    public enum Kind: String, Codable, Sendable { case winter, summer }

    public var kind: Kind
    /// Winter 2025/26 has year 2025; summer 2026 has year 2026.
    public var year: Int

    public init(kind: Kind, year: Int) {
        self.kind = kind
        self.year = year
    }

    public var id: String { "\(kind.rawValue)-\(year)" }

    public var title: String {
        switch kind {
        case .winter: return "Inverno \(year)/\(String(format: "%02d", (year + 1) % 100))"
        case .summer: return "Estate \(year)"
        }
    }

    public static func < (a: Season, b: Season) -> Bool {
        a.sortKey < b.sortKey
    }

    private var sortKey: Int { kind == .winter ? year * 2 + 1 : year * 2 }

    /// Statistics seasons: winter Nov 1 – Apr 30, summer May 1 – Oct 31.
    public static func of(_ date: Date, calendar: Calendar = .current) -> Season {
        let c = calendar.dateComponents([.year, .month], from: date)
        let y = c.year ?? 2000, m = c.month ?? 1
        if m >= 11 { return Season(kind: .winter, year: y) }
        if m <= 4 { return Season(kind: .winter, year: y - 1) }
        return Season(kind: .summer, year: y)
    }

    /// Whether the app should be in winter mode on this day:
    /// from Nov 15 to Apr 30 (snow season in the Alps).
    public static func isWinter(date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: date)
        let m = c.month ?? 1, d = c.day ?? 1
        if m == 11 { return d >= 15 }
        return m == 12 || m <= 4
    }

    public static func resolve(_ mode: SeasonMode, date: Date = Date(), calendar: Calendar = .current) -> Kind {
        switch mode {
        case .automatic: return isWinter(date: date, calendar: calendar) ? .winter : .summer
        case .winter: return .winter
        case .summer: return .summer
        }
    }
}
